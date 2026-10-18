require "cybertrain/kaisatsu/version"
require "cybertrain/kaisatsu/cli/installer"

module Cybertrain
  module Kaisatsu
    # The `kaisatsu` command (CRuby): exe/kaisatsu.
    module CLI
      USAGE = <<~TEXT.freeze
        Usage:
          kaisatsu install [--path DIR | --git URL [--ref R]] [--postal | --postal-path DIR]
              Add Kaisatsu to the cybertrain application in the current
              directory: migrations (users and Kaisatsu's tables), the User model,
              the sign-in/sign-up controllers and views, routes, and the
              before_action that checks the session on every request. Existing
              files are never overwritten. --path points spin.toml at a local
              checkout of cybertrain-kaisatsu; the default is the git repository
              at branch main.
              --postal sends the reset mail over cybertrain-postal (spin.toml
              depends on its git repository; --postal-path DIR uses a local
              checkout). Without it, mail is printed to the log (development).
              Then run: cybertrain db migrate
          kaisatsu version
          kaisatsu help
      TEXT

      # Returns the process exit code.
      def self.run(argv)
        case argv.empty? ? "" : argv[0]
        when "install" then install(argv[1, argv.size - 1])
        when "version", "--version", "-v"
          puts "kaisatsu #{Cybertrain::Kaisatsu::VERSION}"
          0
        when "help", "--help", "-h", ""
          puts USAGE
          0
        else
          warn "kaisatsu: unknown command #{argv[0].inspect}\n\n#{USAGE}"
          1
        end
      end

      def self.install(args)
        path = nil
        git = nil
        ref = nil
        postal = false
        postal_path = nil
        i = 0
        while i < args.size
          case args[i]
          when "--postal" then postal = true
          when "--postal-path"
            postal = true
            postal_path = args[i += 1]
          when "--path" then path = args[i += 1]
          when "--git" then git = args[i += 1]
          when "--ref" then ref = args[i += 1]
          else
            warn "kaisatsu install: unknown option #{args[i].inspect}"
            return 1
          end
          i += 1
        end
        if [path, git, ref].any? { |v| v == "" } || (args.include?("--path") && path.nil?)
          warn "kaisatsu install: an option is missing its value"
          return 1
        end
        postal_dependency = postal ? Installer.postal_dependency_for(postal_path, nil) : nil
        installer = Installer.new(".", Installer.dependency_for(path, git, ref), postal_dependency)
        installer.run.each { |line| puts line }
        puts
        puts "next:"
        puts "  cybertrain db migrate"
        if postal
          puts "  # web:    set KAISATSU_MAIL_FROM and KAISATSU_BASE_URL (see app/models/mail_setup.rb)"
          puts "  # sender:  set KAISATSU_SMTP_HOST (and the rest, see bin/mail_worker.rb), then"
          puts "  #          cybertrain spin run mail_worker"
          puts "  # on macOS, building the worker needs: export LIBRARY_PATH=$(brew --prefix openssl@3)/lib CPATH=$(brew --prefix openssl@3)/include"
        end
        puts "  # protect a controller with:  before_action :require_login"
        puts "  # run the server with SPINEL_WORKERS=2 or more: checking a password takes about half a second"
        0
      rescue ArgumentError => e
        warn "kaisatsu: #{e.message}"
        1
      end
    end
  end
end
