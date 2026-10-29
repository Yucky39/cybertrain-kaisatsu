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

      # The link that confirms the address, to the address being confirmed.
      def send_email_verification(email, link)
        nil
      end

      # The link that confirms a new sign-in address, to the NEW address.
      def send_email_change_link(new_email, link)
        nil
      end

      # To the OLD address: a change was requested (new_email is shown masked
      # by the caller if it wishes) / the address was changed.
      def send_email_change_requested(old_email, new_email)
        nil
      end

      def send_email_changed(old_email, new_email)
        nil
      end

      # To the OLD address, after a change that can be undone: the address was
      # changed to new_email, and the link puts the old one back (valid for a week).
      def send_email_change_undo(old_email, new_email, link)
        nil
      end

      # A security notice after a password was changed or reset.
      def send_password_changed(email)
        nil
      end

      # To the owner of an address somebody tried to sign up with again. The
      # person who tried is told nothing different from a successful sign-up;
      # link leads to "forgot password".
      def send_signup_existing(email, link)
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

      def send_email_verification(email, link)
        puts "[kaisatsu] confirm the address #{email}: #{link}"
        STDOUT.flush
        nil
      end

      def send_email_change_link(new_email, link)
        puts "[kaisatsu] confirm the new address #{new_email}: #{link}"
        STDOUT.flush
        nil
      end

      def send_email_change_requested(old_email, new_email)
        puts "[kaisatsu] #{old_email}: a change to #{new_email} was requested"
        STDOUT.flush
        nil
      end

      def send_email_changed(old_email, new_email)
        puts "[kaisatsu] #{old_email}: the address was changed to #{new_email}"
        STDOUT.flush
        nil
      end

      def send_email_change_undo(old_email, new_email, link)
        puts "[kaisatsu] #{old_email}: the address was changed to #{new_email}; undo: #{link}"
        STDOUT.flush
        nil
      end

      def send_signup_existing(email, link)
        puts "[kaisatsu] #{email}: someone tried to sign up again; forgot password: #{link}"
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
