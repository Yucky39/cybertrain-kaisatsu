require "cybertrain/kaisatsu/token_store"
require "cybertrain/kaisatsu/throttle"
require "cybertrain/kaisatsu/user_directory"
require "cybertrain/kaisatsu/notifier"

module Cybertrain
  module Kaisatsu
    # What confirming an address came to: EmailVerification::DONE or INVALID_TOKEN.
    class VerifyOutcome
      attr_reader :status

      def initialize(status)
        @status = status
      end

      def done?
        @status == "done"
      end
    end

    # Confirms that an e-mail address belongs to the person who gave it.
    #
    #   request_verification  sends the link (right after sign-up, or on request).
    #                         The same answer for any address; throttled per
    #                         account and per address, silently.
    #   token_valid?          the link was opened: offer the "confirm" button.
    #   complete_verification the button was pressed: spends the token.
    #
    # Opening the link must not confirm by itself: mail scanners and link
    # previews fetch links, so only the POST behind the button counts.
    class EmailVerification
      DONE = "done"
      INVALID_TOKEN = "invalid_token"

      TTL = 259_200
      ACCOUNT_LIMIT = 3
      IP_LIMIT = 10
      WINDOW = 3600

      def initialize(directory, notifier, base_url)
        @directory = directory
        @notifier = notifier
        @base_url = base_url
      end

      def link_for(raw)
        @base_url + "/email/verify/" + raw
      end

      # Counts a request against the per-account and per-address limits and says
      # whether it may go ahead.
      def allowed?(conn, name, ip, now)
        account_key = "verify:" + name
        ip_key = "verify-ip:" + ip
        return false if Throttle.blocked?(conn, account_key, now, ACCOUNT_LIMIT, WINDOW)
        return false if ip.bytesize > 0 && Throttle.blocked?(conn, ip_key, now, IP_LIMIT, WINDOW)
        Throttle.note_failure(conn, account_key, now, WINDOW)
        Throttle.note_failure(conn, ip_key, now, WINDOW) if ip.bytesize > 0
        true
      end

      # Someone signed up with an address that already has an account. The
      # caller answers exactly as for a new account, so the form does not reveal
      # who has one; this mails the owner instead. A confirmed account gets a
      # notice with the "forgot password" link; one still unconfirmed gets its
      # confirmation link again. Returns nothing.
      def signup_again(conn, email, ip, now)
        name = email.strip.downcase
        creds = @directory.credentials_for(name)
        if creds.found && @directory.email_verified?(creds.user_id)
          if allowed?(conn, name, ip, now)
            @notifier.send_signup_existing(name, @base_url + "/password/forgot")
          end
          return nil
        end
        request_verification(conn, name, ip, now)
      end

      # Returns nothing: the caller answers the same way in every case.
      def request_verification(conn, email, ip, now)
        name = email.strip.downcase
        return nil unless allowed?(conn, name, ip, now)

        creds = @directory.credentials_for(name)
        return nil unless creds.found
        return nil if @directory.email_verified?(creds.user_id)
        raw = TokenStore.save_token(conn, creds.user_id, TokenStore::PURPOSE_VERIFY, now, TTL)
        @notifier.send_email_verification(name, link_for(raw))
        nil
      end

      def token_valid?(conn, raw, now)
        TokenStore.peek_token(conn, raw, TokenStore::PURPOSE_VERIFY, now).bytesize > 0
      end

      def complete_verification(conn, raw, now)
        user_id = TokenStore.consume_token(conn, raw, TokenStore::PURPOSE_VERIFY, now)
        return VerifyOutcome.new(INVALID_TOKEN) if user_id.empty?
        @directory.mark_email_verified(user_id)
        VerifyOutcome.new(DONE)
      end
    end
  end
end
