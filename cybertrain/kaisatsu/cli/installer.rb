require "fileutils"
require "cybertrain/kaisatsu/version"
require "cybertrain/kaisatsu/cli/templates"

module Cybertrain
  module Kaisatsu
    module CLI
      # `kaisatsu install`: adds Kaisatsu to the cybertrain application in the
      # current directory. Runs under CRuby (the generator, like cybertrain's
      # own CLI), writes plain Ruby, and never overwrites a file that exists
      # (it says "skip"); the edits to existing files are small and idempotent.
      class Installer
        REPOSITORY = "https://github.com/Yucky39/cybertrain-kaisatsu".freeze
        # The tag a new application depends on when --ref is not given. A branch
        # would move under the application between two builds.
        DEFAULT_REF = "v0.0.3".freeze
        # cybertrain-postal is tagged on its own.
        POSTAL_DEFAULT_REF = "v0.0.2".freeze

        attr_reader :log

        # dependency: the right-hand side of the spin.toml line, for example
        # `{ path = "/src/cybertrain-kaisatsu" }`.
        POSTAL_REPOSITORY = "https://github.com/Yucky39/cybertrain-postal".freeze

        # postal_dependency: nil for no mail sending (the console notifier), or the
        # right-hand side of the cybertrain-postal line in spin.toml.
        def initialize(root, dependency, postal_dependency = nil)
          @root = root
          @dependency = dependency
          @postal_dependency = postal_dependency
          @log = []
        end

        def self.postal_dependency_for(path, ref)
          return %({ path = "#{File.expand_path(path)}" }) unless path.nil?
          %({ git = "#{POSTAL_REPOSITORY}", ref = "#{ref || POSTAL_DEFAULT_REF}" })
        end

        def self.dependency_for(path, git, ref)
          return %({ path = "#{File.expand_path(path)}" }) unless path.nil?
          %({ git = "#{git || REPOSITORY}", ref = "#{ref || DEFAULT_REF}" })
        end

        def run
          check_application!
          stamp = Time.now.utc.strftime("%Y%m%d%H%M")
          Templates::FILES.each do |path, content|
            write_new(path.sub("%{ts}", stamp), content)
          end
          write_new("app/models/mail_setup.rb", @postal_dependency ? Templates::MAIL_SETUP_POSTAL : Templates::MAIL_SETUP_CONSOLE)
          write_new("bin/mail_worker.rb", Templates::MAIL_WORKER) if @postal_dependency
          patch_spin_toml
          patch_config_app
          patch_application_controller
          patch_routes
          @log
        end

        private

        def check_application!
          %w[spin.toml config/routes.rb app/controllers/application_controller.rb config/app.rb].each do |f|
            next if File.exist?(File.join(@root, f))
            raise ArgumentError, "#{f} not found: run this in a cybertrain application's directory"
          end
        end

        def path_of(rel)
          File.join(@root, rel)
        end

        def write_new(rel, content)
          full = path_of(rel)
          # A migration is "already there" when one with the same name exists,
          # whatever its timestamp, so a second run does not add a duplicate.
          if rel.start_with?("db/migrate/")
            name = rel.sub(%r{\Adb/migrate/\d+_}, "")
            if Dir.glob(path_of("db/migrate/*_#{name}")).any?
              @log << "skip   #{rel} (a #{name} migration exists)"
              return
            end
          elsif File.exist?(full)
            @log << "skip   #{rel} (exists)"
            return
          end
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
          @log << "create #{rel}"
        end

        def patch_spin_toml
          full = path_of("spin.toml")
          text = File.read(full)
          added = []
          unless text.include?("cybertrain-kaisatsu")
            added << "cybertrain-kaisatsu = #{@dependency}\n"
          end
          if @postal_dependency && !text.include?("cybertrain-postal")
            added << "cybertrain-postal = #{@postal_dependency}\n"
          end
          if added.empty?
            @log << "skip   spin.toml (dependencies already there)"
            return
          end
          text += "\n" unless text.end_with?("\n")
          text += "[dependencies]\n" unless text.include?("[dependencies]")
          text += added.join
          File.write(full, text)
          @log << "update spin.toml"
        end

        def patch_config_app
          full = path_of("config/app.rb")
          text = File.read(full)
          additions = +""
          additions << Templates::REQUIRE_LINE unless text.include?("cybertrain/kaisatsu")
          if @postal_dependency && !text.include?("cybertrain/postal")
            additions << Templates::POSTAL_REQUIRES
          end
          if additions.empty?
            @log << "skip   config/app.rb (already requires what it needs)"
            return
          end
          File.write(full, additions + "\n" + text)
          @log << "update config/app.rb"
        end

        def patch_application_controller
          full = path_of("app/controllers/application_controller.rb")
          text = File.read(full)
          if text.include?("Kaisatsu::Gate")
            @log << "skip   app/controllers/application_controller.rb (already patched)"
            return
          end
          head = /^class ApplicationController < Cybertrain::Controller\n/
          unless text.match?(head)
            @log << "MANUAL app/controllers/application_controller.rb: add the before_action and helpers from docs/install.md"
            return
          end
          text = text.sub(head) { |m| m + indent(Templates::APPLICATION_CONTROLLER_BEFORE_ACTION) + "\n" }
          helpers = indent(Templates::APPLICATION_CONTROLLER_HELPERS)
          if text.match?(/^  private\n/)
            text = text.sub(/^  private\n/) { |m| m + "\n" + helpers }
          else
            text = text.sub(/^end\s*\z/) { "\n  private\n\n" + helpers + "end\n" }
          end
          File.write(full, text)
          @log << "update app/controllers/application_controller.rb"
        end

        # Adds each route that is not there yet, so an application installed by an
        # earlier version gains the newer routes on a second run.
        def patch_routes
          full = path_of("config/routes.rb")
          text = File.read(full)
          missing = Templates::ROUTES.lines.reject { |line| text.include?(line.strip) }
          if missing.empty?
            @log << "skip   config/routes.rb (already has the routes)"
            return
          end
          unless text.match?(/^end\s*\z/)
            @log << "MANUAL config/routes.rb: add the routes from docs/install.md"
            return
          end
          separator = text.match?(/^  \S/) ? "\n" : ""
          addition = indent(missing.join)
          text = text.sub(/^end\s*\z/) { separator + addition + "end\n" }
          File.write(full, text)
          @log << "update config/routes.rb"
        end

        def indent(block)
          block.lines.map { |l| l.strip.empty? ? l : "  " + l }.join
        end
      end
    end
  end
end
