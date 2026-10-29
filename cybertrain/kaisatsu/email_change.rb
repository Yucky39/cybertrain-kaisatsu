require "cybertrain/kaisatsu/password_hash"
require "cybertrain/kaisatsu/token_store"
require "cybertrain/kaisatsu/throttle"
require "cybertrain/kaisatsu/server_sessions"
require "cybertrain/kaisatsu/user_directory"
require "cybertrain/kaisatsu/notifier"

module Cybertrain
  module Kaisatsu
    # What a request to change the sign-in address came to. status is
    # EmailChange::ACCEPTED (the same answer whatever happened to the mail),
    # WRONG_PASSWORD, INVALID_EMAIL or THROTTLED.
    class ChangeRequestOutcome
      attr_reader :status

      def initialize(status)
        @status = status
      end

      def accepted?
        @status == "accepted"
      end
    end

    # What pressing the confirm button came to: DONE, INVALID_TOKEN or TAKEN.
    class ChangeOutcome
      attr_reader :status

      def initialize(status)
        @status = status
      end

      def done?
        @status == "done"
      end
    end

    # Changing the address a person signs in with, and gets mail at.
    #
    #   request_change   a signed-in person, who types their password again, names
    #                    the new address. Nothing changes yet: a link goes to the
    #                    NEW address, and a notice to the old one. Whether the new
    #                    address is already taken is not revealed (the answer is
    #                    ACCEPTED and no mail is sent), so this cannot be used to
    #                    find out who has an account.
    #   token_valid?     the link was opened: offer the "confirm" button.
    #   complete_change  the button was pressed: the address changes, counts as
    #                    confirmed, every session and every outstanding link of the
    #                    account ends, and the old address is told.
    class EmailChange
      ACCEPTED = "accepted"
      WRONG_PASSWORD = "wrong_password"
      INVALID_EMAIL = "invalid_email"
      THROTTLED = "throttled"

      DONE = "done"
      INVALID_TOKEN = "invalid_token"
      TAKEN = "taken"

      TTL = 86_400
      LIMIT = 3
      WINDOW = 3600

      def initialize(directory, notifier, base_url)
        @directory = directory
        @notifier = notifier
        @base_url = base_url
      end

      def link_for(raw)
        @base_url + "/email/change/" + raw
      end

      # A cheap shape check; the real proof is the mail that arrives.
      def self.plausible?(email)
        return false if email.bytesize < 3 || email.bytesize > 254
        at = email.index("@")
        return false if at.nil? || at == 0 || at == email.bytesize - 1
        return false if email.index("@", at + 1)
        i = 0
        while i < email.bytesize
          b = email.getbyte(i)
          return false if b <= 32 || b >= 127
          i += 1
        end
        true
      end

      def request_change(conn, user_id, new_email, password, now)
        old_email = @directory.email_for(user_id)
        return ChangeRequestOutcome.new(INVALID_EMAIL) if old_email.empty?
        target = new_email.strip.downcase
        return ChangeRequestOutcome.new(INVALID_EMAIL) unless EmailChange.plausible?(target)
        return ChangeRequestOutcome.new(INVALID_EMAIL) if target == old_email

        # The password is the proof that the person at the keyboard is the owner.
        # A wrong one counts against the account's sign-in counter, and is
        # refused at the limit one address gets there (Authenticator::PAIR_LIMIT),
        # so this form cannot be used to guess it.
        sign_in_key = "account:" + old_email
        change_key = "change:" + user_id
        if Throttle.blocked?(conn, sign_in_key, now, Authenticator::PAIR_LIMIT, Authenticator::WINDOW) ||
           Throttle.blocked?(conn, change_key, now, LIMIT, WINDOW)
          return ChangeRequestOutcome.new(THROTTLED)
        end
        creds = @directory.credentials_for(old_email)
        verified = creds.found && PasswordHash.verify(password, creds.password_hash)
        unless verified
          PasswordHash.dummy_verify(password) unless creds.found
          Throttle.note_failure(conn, sign_in_key, now, Authenticator::WINDOW)
          return ChangeRequestOutcome.new(WRONG_PASSWORD)
        end
        Throttle.note_failure(conn, change_key, now, WINDOW)

        return ChangeRequestOutcome.new(ACCEPTED) if @directory.email_taken?(target, user_id)
        @directory.begin_email_change(user_id, target)
        raw = TokenStore.save_token(conn, user_id, TokenStore::PURPOSE_CHANGE, now, TTL)
        @notifier.send_email_change_link(target, link_for(raw))
        @notifier.send_email_change_requested(old_email, target) if @directory.email_verified?(user_id)
        ChangeRequestOutcome.new(ACCEPTED)
      end

      def token_valid?(conn, raw, now)
        TokenStore.peek_token(conn, raw, TokenStore::PURPOSE_CHANGE, now).bytesize > 0
      end

      def complete_change(conn, raw, now)
        user_id = TokenStore.consume_token(conn, raw, TokenStore::PURPOSE_CHANGE, now)
        return ChangeOutcome.new(INVALID_TOKEN) if user_id.empty?
        old_email = @directory.email_for(user_id)
        pending = @directory.pending_email(user_id)
        return ChangeOutcome.new(INVALID_TOKEN) if pending.empty?
        return ChangeOutcome.new(TAKEN) unless @directory.apply_email_change(user_id)
        # Everything issued before the change belonged to the old address: other
        # sessions, and reset or confirmation links sitting in the old mailbox.
        ServerSessions.close_all_for(conn, user_id)
        TokenStore.void_tokens(conn, user_id)
        @notifier.send_email_changed(old_email, pending) if old_email.bytesize > 0
        ChangeOutcome.new(DONE)
      end
    end
  end
end
