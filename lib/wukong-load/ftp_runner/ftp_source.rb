require_relative("default_file_handler")
require_relative("mirrored_files")

module Wukong
  module Load
    module FTP

      # Describes a source of FTP data.
      #
      # Design goals include
      #
      # * provide an abstraction between the various and confusing types of FTP service (SFTP vs FTPS)
      # * support "once and exactly once" processing for **whole files**
      # * be part of a pluggable toolchain
      # * integrate well with logging and notification systems (e.g. Vayacondios)
      #
      # @example Mirror a local FTP server using an anonymous account
      #
      #   ftp_source = FTPSource.new(name: 'local-root', output: '/tmp/ftp/raw', links: '/tmp/ftp/clean')
      #   newly_downloaded_paths = ftp_source.mirror # downloads files and updates hardlinks (if necessary)
      #
      # @example Mirror a remote SFTP server using the account 'bob'
      #
      #   ftp_source = FTPSource.new(name: 'west-coast', protocol: 'sftp', host: 'ftp.example.com', username: 'bob', password: 'ross', path: '/systemX/2017/03', output: '/tmp/ftp/raw', links: '/tmp/ftp/clean')
      #   newly_downloaded_paths = ftp_source.mirror # downloads files and updates hardlinks (if necessary)
      #
      # Depends upon the [`lftp`](http://lftp.yar.ru/) tool being
      # available on the system.
      class FTPSource

        include Logging

        # A mapping between protocal names and the standard ports
        # those services run on.
        PROTOCOLS = {
          'ftp'  => 21,
          'ftps' => 443,
          'sftp' => 22
        }.freeze

        # The verbosity level passed to the `lftp` program
        VERBOSITY = 3

        attr_accessor :settings, :finished_files, :mirrored_files, :previously_mirrored_files

        # Create a new FTP source.
        #
        # @example Create a source for a local FTP server using an anonymous account
        #
        #   Wukong::Load::FTP::FTPSource.new(name: 'local-root', output: '/tmp/ftp/raw', links: '/tmp/ftp/clean')
        #
        # @example Create a source for a remote SFTP server using the account 'bob'
        #
        #   Wukong::Load::FTP::FTPSource.new(name: 'west-coast', protocol: 'sftp', host: 'ftp.example.com', username: 'bob', password: 'ross', path: '/systemX/2017/03', output: '/tmp/ftp/raw', links: '/tmp/ftp/clean')
        #
        def initialize settings
          self.settings = settings
          self.finished_files            = MirroredFiles.new(settings[:name])
          self.mirrored_files            = MirroredFiles.new(settings[:name])
          self.previously_mirrored_files = MirroredFiles.new(settings[:name])
        end

        # Validates this FTP source.  Checks
        #
        # * the protocol is valid (one of `ftp`, `ftps`, or `sftp`)
        # * a host is given
        # * a path is given
        # * a local output directory for downlaoded data is given
        # * a local links directory for lexicographically ordered hardlinks to data is given
        # * a name is given
        # 
        # @return [true] if the source if valid
        # @raise [Wukong::Error] if the source is not valid
        def validate
          raise Error.new("Unsupported --protocol: <#{settings[:protocol]}>") unless PROTOCOLS.include?(settings[:protocol])
          raise Error.new("A --host is required") if settings[:host].nil? || settings[:host].empty?
          raise Error.new("A --path is required") if settings[:path].nil? || settings[:path].empty?
          raise Error.new("A local --output directory is required") if settings[:output].nil? || settings[:output].empty?
          raise Error.new("A local --links directory is required")  if settings[:links].nil? || settings[:links].empty?
          raise Error.new("The --name of a directory within the output directory is required") if settings[:name].nil? || settings[:name].empty?
          true
        end

        # The port to use for this FTP source.
        #
        # If we were given an explicit port, then use that, otherwise
        # use the standard port given the protocol.
        #
        # @return [Integer] the port
        def port
          settings[:port] || PROTOCOLS[settings[:protocol]]
        end

        # Mirror the content at the remote FTP server to the local
        # output directory and create a lexicographically ordered
        # representation of this data in the links directory.
        #
        # @see #file_handler for the class which constructs local hardlinks based on remote FTP paths
        def mirror
          user_msg = settings[:username] ? "#{settings[:username]}@" : ''
          log.info("Mirroring #{settings[:protocol]} #{user_msg}#{settings[:host]}:#{port}#{settings[:path]}")
          command = send("#{settings[:protocol]}_command")
          mirrored_files.clear
          if settings[:dry_run]
            log.info(command)
          else
            IO.popen(command).each { |line| handle_output(line) }
          end
          file_handler.close
        end

        # Handle a line of output from the `lftp` subprocess.
        #
        # Will look for `Transferring file...` lines which indicate a
        # new filename should be added to the list of
        # `mirrored_paths`.
        #
        # Will also log the output `line` at the DEBUG level so the
        # user can see what `lftp` is doing.
        #
        # @param [String] a new line of output from `lftp`
        def handle_output line
          log.debug(line.chomp)
          if path = newly_downloaded_path?(line)
            self.mirrored_files[path] = true
          end
        end

        # Compares the `mirrored_files` to the
        # `previously_mirrored_files` to determine which files are
        # **complete**: they appeared in the former but **not** the
        # latter.
        #
        # For each of these completed files, has the `file_handler`
        # process it.
        #
        # @see FTPFileHandler#process_finished
        def handle_newly_mirrored_files
          previously_mirrored_files.load
          finished_files.clear
          (previously_mirrored_files.keys - mirrored_files.keys).each do |filename|
            begin
              file_handler.process_finished(filename)
              finished_files[filename] = true
            rescue => e
              log.error("Could not handle finished file <#{filename}>: #{e.class} -- #{e.message}")
              e.backtrace.each { |line| log.debug(line) }
              next
            end
          end
          self.previously_mirrored_files = self.mirrored_files
          self.previously_mirrored_files.save
        end

        # Does the `line` indicate a newly downloaded path from the
        # remote FTP server?
        #
        # @param [String] line
        # @return [String, nil] the path that was downloaded or `nil` if none was
        def newly_downloaded_path? line
          return unless line.include?("Transferring file")
          return unless line =~ /`(.*)'/
          $1
        end

        # The file handler that will process each newly downloaded
        # path and create appropriate hardlinks on disk.
        #
        # The FTPFileHandler is the default.
        #
        # @return [FTPFileHandler]
        # @see FTPFileHandler
        def file_handler
          @file_handler ||= FTPFileHandler.new(settings)
        end

        # The command to use when using the FTP protocol.
        #
        # @return [String]
        def ftp_command
          lftp_command
        end

        # The command to use when using the FTPS protocol.
        #
        # @return [String]
        def ftps_command
          lftp_command('set ftps:initial-prot "";', 'set ftp:ssl-force true;', 'set ftp:ssl-protect-data true;')
        end

        # The command to use when using the SFTP protocol.
        #
        # @return [String]
        def sftp_command
          lftp_command
        end

        # Construct an `lftp` command-line from the settings for this
        # source as well as the given `subcommands`.
        #
        # @param [Array<String>] subcommands each terminated with a semi-colon (`;')
        def lftp_command *subcommands
          command = ["#{lftp_program} -c 'open -e \""]
          command += subcommands
          command << "set ssl:verify-certificate no;" if settings[:ignore_unverified]
          command << "mirror --verbose=#{VERBOSITY} #{settings[:path]} #{settings[:output]}/#{settings[:name]};"
          command << "exit"
          
          auth = ""
          if settings[:username] || settings[:password]
            auth += "-u "
            if settings[:username]
              auth += settings[:username]
              if settings[:password]
                auth += ",#{settings[:password]}"
              end
              auth += " "
            end
          end
          command << "\" -p #{port} #{auth} #{settings[:protocol]}://#{settings[:host]}'"
          command.flatten.compact.join(" \t\\\n  ")
        end

        # The path on disk for the `lftp` program.
        #
        # @return [String]
        def lftp_program
          settings[:lftp_program] || 'lftp'
        end
        
      end
    end
  end
end

