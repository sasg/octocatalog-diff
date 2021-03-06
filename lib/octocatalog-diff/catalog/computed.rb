require 'fileutils'
require 'json'
require 'open3'
require 'stringio'

require_relative '../catalog-util/bootstrap'
require_relative '../catalog-util/builddir'
require_relative '../catalog-util/command'
require_relative '../util/puppetversion'
require_relative '../catalog-util/facts'

module OctocatalogDiff
  class Catalog
    # Represents a Puppet catalog that is computed (via `puppet master --compile ...`)
    # By instantiating this class, the catalog is computed.
    class Computed
      attr_reader :node, :error_message, :catalog, :catalog_json, :retries

      # Constructor
      # @param :node [String] REQUIRED: Node name
      # @param :basedir [String] Directory in which to compile the catalog
      # @param :pass_env_vars [Array<String>] Environment variables to pass when compiling catalog
      # @param :retry_failed_catalog [Fixnum] Number of retries if a catalog compilation fails
      # @param :tag [String] For display purposes, the catalog being compiled
      # @param :puppet_binary [String] Full path to Puppet
      # @param :puppet_version [String] Puppet version (optional; if not supplied, it is calculated)
      # @param :puppet_command [String] Full command to run Puppet (optional; if not supplied, it is calculated)
      def initialize(options)
        raise ArgumentError, 'Usage: OctocatalogDiff::Catalog::Computed.initialize(options_hash)' unless options.is_a?(Hash)
        raise ArgumentError, 'Node name must be passed to OctocatalogDiff::Catalog::Computed' unless options[:node].is_a?(String)

        # Standard readable variables
        @node = options[:node]
        @error_message = nil
        @catalog = nil
        @catalog_json = nil

        # Additional class variables
        @pass_env_vars = options.fetch(:pass_env_vars, [])
        @retry_failed_catalog = options.fetch(:retry_failed_catalog, 0)
        @tag = options.fetch(:tag, 'catalog')
        @puppet_binary = options[:puppet_binary]
        @puppet_version = options[:puppet_version]
        @puppet_command = options[:puppet_command]
        @retries = nil
        @builddir = nil
        @facts_terminus = options.fetch(:facts_terminus, 'yaml')

        # Pass through the input for other access
        @opts = options
        raise ArgumentError, 'Branch is undefined' unless @opts[:branch]
      end

      # Actually build the catalog (populate @error_message, @catalog, @catalog_json)
      def build(logger = Logger.new(StringIO.new))
        if @facts_terminus != 'facter'
          facts_obj = OctocatalogDiff::CatalogUtil::Facts.new(@opts, logger)
          logger.debug "Start retrieving facts for #{@node} from #{self.class}"
          @opts[:facts] = facts_obj.facts
          logger.debug "Success retrieving facts for #{@node} from #{self.class}"
        end
        build_catalog(logger)
      end

      # Get the Puppet version
      # @return [String] Puppet version
      def puppet_version
        raise ArgumentError, '"puppet_binary" was not passed to OctocatalogDiff::Catalog::Computed' unless @puppet_binary
        @puppet_version ||= OctocatalogDiff::Util::PuppetVersion.puppet_version(@puppet_binary)
      end

      # Compilation directory
      # @return [String] Compilation directory
      def compilation_dir
        raise 'Catalog was not built' if @builddir.nil?
        @builddir.tempdir
      end

      private

      # Private method: Clean up a checkout directory, if it exists
      def cleanup_checkout_dir(checkout_dir, logger)
        return unless File.directory?(checkout_dir)
        logger.debug("Cleaning up temporary directory #{checkout_dir}")
        FileUtils.remove_entry_secure checkout_dir
      end

      # Private method: Bootstrap a directory
      def bootstrap(logger)
        return if @builddir

        # Fill options for creating and populating the temporary directory
        tmphash = @opts.dup

        # Bootstrap directory if needed
        if !@opts[:bootstrapped_dir].nil?
          raise Errno::ENOENT, "Invalid dir #{@opts[:bootstrapped_dir]}" unless File.directory?(@opts[:bootstrapped_dir])
          tmphash[:basedir] = @opts[:bootstrapped_dir]
        elsif @opts[:branch] == '.'
          tmphash[:basedir] = @opts[:basedir]
        else
          checkout_dir = Dir.mktmpdir
          at_exit { cleanup_checkout_dir(checkout_dir, logger) }
          tmphash[:basedir] = checkout_dir
          OctocatalogDiff::CatalogUtil::Bootstrap.bootstrap_directory(@opts.merge(path: checkout_dir), logger)
        end

        # Create and populate the temporary directory
        @builddir ||= OctocatalogDiff::CatalogUtil::BuildDir.new(tmphash, logger)
      end

      # Private method: Build catalog by running Puppet
      # @param logger [Logger] Logger object
      def build_catalog(logger = nil)
        return nil unless @catalog.nil? && @error_message.nil?
        bootstrap(logger)
        result = run_puppet(logger)
        @retries = result[:retries]
        if (result[:exitcode]).zero?
          begin
            @catalog = ::JSON.parse(result[:stdout])
            @catalog_json = result[:stdout]
            @error_message = nil
          rescue ::JSON::ParserError => exc
            @catalog = nil
            @catalog_json = nil
            @error_message = "Catalog has invalid JSON: #{exc.message}"
          end
        else
          @error_message = result[:stderr]
          @catalog = nil
          @catalog_json = nil
        end
      end

      # Get the command to compile the catalog
      # @return [String] Puppet command line
      def puppet_command(options = @opts)
        return @puppet_command if @puppet_command
        raise ArgumentError, '"puppet_binary" was not passed to OctocatalogDiff::Catalog::Computed' unless @puppet_binary
        command_opts = options.merge(
          node: @node,
          compilation_dir: @builddir.tempdir,
          parser: options.fetch(:parser, :default),
          puppet_binary: @puppet_binary,
          fact_file: @builddir.fact_file,
          dir: @builddir.tempdir,
          enc: @builddir.enc
        )
        command = OctocatalogDiff::CatalogUtil::Command.new(command_opts)
        @puppet_command = command.puppet_command
      end

      # Private method: Actually execute puppet
      # @return [Hash] { stdout, stderr, exitcode }
      def exec_puppet
        # This is the environment provided to the puppet command.
        env = {
          'HOME' => ENV['HOME'],
          'PATH' => ENV['PATH'],
          'PWD' => @builddir.tempdir
        }
        @pass_env_vars.each { |var| env[var] ||= ENV[var] }
        out, err, status = Open3.capture3(env, puppet_command, unsetenv_others: true, chdir: @builddir.tempdir)
        {
          stdout: out,
          stderr: err,
          exitcode: status.exitstatus
        }
      end

      # Private method: Runs puppet on the command line to compile the catalog
      # Exit code is 0 if catalog generation was successful, non-zero otherwise.
      # @param logger [Logger] Logger object
      # @return [Hash] { stdout: <catalog as JSON>, stderr: <error messages>, exitcode: <hopefully 0> }
      def run_puppet(logger)
        # Run 'cmd' with environment 'env' from directory 'dir'
        # First line of a successful result needs to be stripped off. It will look like:
        # Notice: Compiled catalog for xxx in environment production in 27.88 seconds
        retval = {}
        0.upto(@retry_failed_catalog) do |retry_num|
          @retries = retry_num
          time_begin = Time.now
          logger.debug("(#{@tag}) Try #{1 + retry_num} executing Puppet #{puppet_version}: #{puppet_command}")
          result = exec_puppet

          # Success
          if (result[:exitcode]).zero?
            logger.debug("(#{@tag}) Catalog succeeded on try #{1 + retry_num} in #{Time.now - time_begin} seconds")
            first_brace = result[:stdout].index('{') || 0
            retval = {
              stdout: result[:stdout][first_brace..-1],
              stderr: nil,
              exitcode: 0,
              retries: retry_num
            }
            break
          end

          # Failure
          logger.debug("(#{@tag}) Catalog failed on try #{1 + retry_num} in #{Time.now - time_begin} seconds")
          retval = result.merge(retries: retry_num)
        end
        retval
      end
    end
  end
end
