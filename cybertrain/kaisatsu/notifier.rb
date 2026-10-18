module Cybertrain
  module Kaisatsu
    # How Kaisatsu tells a user something by e-mail. The application subclasses
    # it (over cybertrain-postal, or anything else); the base does nothing, so
    # the hooks are declared for Spinel (spikes/NOTES.md rule 3). Methods may be
    # called from a background thread: they must not touch the request.
    class Notifier
      # The reset link, to the address the user typed.
      def send_password_reset(email, link)
        nil
      end

      # A security notice after a password was changed or reset.
      def send_password_changed(email)
        nil
      end
    end

    # Prints to standard output. For development only: it writes the reset link
    # (a secret) to the log. Replace it in production.
    class ConsoleNotifier < Notifier
      def send_password_reset(email, link)
        puts "[kaisatsu] password reset for #{email}: #{link}"
        STDOUT.flush
        nil
      end

      def send_password_changed(email)
        puts "[kaisatsu] password changed for #{email}"
        STDOUT.flush
        nil
      end
    end
  end
end
