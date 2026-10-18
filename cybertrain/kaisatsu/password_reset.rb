require "cybertrain/kaisatsu/password_hash"
require "cybertrain/kaisatsu/authenticator"
require "cybertrain/kaisatsu/token_store"
require "cybertrain/kaisatsu/throttle"
require "cybertrain/kaisatsu/notifier"

module Cybertrain
  module Kaisatsu
    # What a reset attempt came to. status is PasswordReset::DONE, INVALID_TOKEN
    # or WEAK_PASSWORD; message is the policy text for WEAK_PASSWORD, else "".
    class ResetOutcome
      attr_reader :status, :message

      def initialize(status, message)
        @status = status
        @message = message
      end

      def done?
        @status == "done"
      end
    end

    # Forgotten-password flow: a one-time link, valid for an hour.
    #
    #   request_reset   POST "forgot": the same answer whether or not the
    #                   account exists; requests are throttled per account and
    #                   per address, silently.
    #   token_valid?    GET the link: show the form only for a live token.
    #   complete_reset  POST the new password: spends the token, stores the
    #                   hash, ends every session of the user.
    class PasswordReset
      DONE = "done"
      INVALID_TOKEN = "invalid_token"
      WEAK_PASSWORD = "weak_password"

      TTL = 3600
      ACCOUNT_LIMIT = 3
      IP_LIMIT = 10
      WINDOW = 3600

      # base_url: where the link points, fixed by the application (never taken
      # from the request's Host header, which a client controls).
      def initialize(authenticator, directory, notifier, base_url)
        @authenticator = authenticator
        @directory = directory
        @notifier = notifier
        @base_url = base_url
      end

      def link_for(raw)
        @base_url + "/password/reset/" + raw
      end

      # Returns nothing: the caller answers the same way in every case.
      def request_reset(conn, email, ip, now)
        name = email.strip.downcase
        account_key = "reset:" + name
        ip_key = "reset-ip:" + ip
        return nil if Throttle.blocked?(conn, account_key, now, ACCOUNT_LIMIT, WINDOW)
        return nil if ip.bytesize > 0 && Throttle.blocked?(conn, ip_key, now, IP_LIMIT, WINDOW)
        # Counted whether or not the account exists, so the count itself
        # reveals nothing.
        Throttle.note_failure(conn, account_key, now, WINDOW)
        Throttle.note_failure(conn, ip_key, now, WINDOW) if ip.bytesize > 0

        creds = @directory.credentials_for(name)
        return nil unless creds.found
        raw = TokenStore.save_token(conn, creds.user_id, TokenStore::PURPOSE_RESET, now, TTL)
        @notifier.send_password_reset(name, link_for(raw))
        nil
      end

      def token_valid?(conn, raw, now)
        TokenStore.peek_token(conn, raw, TokenStore::PURPOSE_RESET, now).bytesize > 0
      end

      def complete_reset(conn, raw, new_password, now)
        # The password is checked first, so a weak one does not spend the link.
        policy = PasswordHash.policy_error(new_password)
        if policy.bytesize > 0
          return ResetOutcome.new(WEAK_PASSWORD, policy) if token_valid?(conn, raw, now)
          return ResetOutcome.new(INVALID_TOKEN, "")
        end
        user_id = TokenStore.consume_token(conn, raw, TokenStore::PURPOSE_RESET, now)
        return ResetOutcome.new(INVALID_TOKEN, "") if user_id.empty?
        @authenticator.change_password(conn, user_id, new_password)
        address = @directory.email_for(user_id)
        @notifier.send_password_changed(address) if address.bytesize > 0
        ResetOutcome.new(DONE, "")
      end
    end
  end
end
