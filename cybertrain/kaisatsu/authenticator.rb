require "cybertrain/kaisatsu/password_hash"
require "cybertrain/kaisatsu/user_directory"
require "cybertrain/kaisatsu/server_sessions"
require "cybertrain/kaisatsu/throttle"

module Cybertrain
  module Kaisatsu
    # Outcome of a sign-in attempt. status is one of Authenticator::OK,
    # INVALID (wrong login or password: deliberately one answer for both) or
    # THROTTLED. session_id is the raw id for the cookie, "" unless OK.
    class LoginResult
      attr_reader :status, :user_id, :session_id

      def initialize(status, user_id, session_id)
        @status = status
        @user_id = user_id
        @session_id = session_id
      end

      def ok?
        @status == "ok"
      end
    end

    # Sign-in and password changes. Pure of HTTP: conn is a
    # Cybertrain::DB::Connection, now is epoch seconds, ip a String ("" when
    # unknown). The caller (a controller, via Gate.sign_in) puts the returned
    # session id into the cookie session.
    class Authenticator
      OK = "ok"
      INVALID = "invalid"
      THROTTLED = "throttled"

      ACCOUNT_LIMIT = 5
      IP_LIMIT = 20
      WINDOW = 900
      SESSION_TTL = 1_209_600

      def initialize(directory)
        @directory = directory
      end

      def login(conn, login, password, ip, now)
        name = login.strip.downcase
        account_key = "account:" + name
        ip_key = "ip:" + ip
        if Throttle.blocked?(conn, account_key, now, ACCOUNT_LIMIT, WINDOW) ||
           (ip.bytesize > 0 && Throttle.blocked?(conn, ip_key, now, IP_LIMIT, WINDOW))
          return LoginResult.new(THROTTLED, "", "")
        end

        creds = @directory.credentials_for(name)
        verified = false
        if creds.found
          verified = PasswordHash.verify(password, creds.password_hash)
        else
          PasswordHash.dummy_verify(password)
        end

        unless verified
          Throttle.note_failure(conn, account_key, now, WINDOW)
          Throttle.note_failure(conn, ip_key, now, WINDOW) if ip.bytesize > 0
          return LoginResult.new(INVALID, "", "")
        end

        Throttle.clear(conn, account_key)
        if PasswordHash.needs_rehash?(creds.password_hash) && PasswordHash.policy_error(password).empty?
          @directory.store_password_hash(creds.user_id, PasswordHash.create(password))
        end
        sid = ServerSessions.open_session(conn, creds.user_id, now, SESSION_TTL)
        LoginResult.new(OK, creds.user_id, sid)
      end

      def logout(conn, session_id)
        ServerSessions.close_session(conn, session_id)
      end

      # After a password change or reset: ends every session of the user and
      # stores the new hash. Returns "" or the policy error.
      def change_password(conn, user_id, new_password)
        err = PasswordHash.policy_error(new_password)
        return err if err.bytesize > 0
        @directory.store_password_hash(user_id, PasswordHash.create(new_password))
        ServerSessions.close_all_for(conn, user_id)
        ""
      end
    end
  end
end
