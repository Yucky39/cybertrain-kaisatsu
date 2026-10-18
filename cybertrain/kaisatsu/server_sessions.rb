require "cybertrain/kaisatsu/secure"
require "cybertrain/kaisatsu/token"

module Cybertrain
  module Kaisatsu
    # Server-side sign-in sessions. The cookie session carries only the random
    # session id; the database holds its digest, so a session can be ended
    # from the server (sign out, sign out everywhere, password reset) and a
    # database leak yields no usable id. `now` is epoch seconds, passed in by
    # the caller. conn is a Cybertrain::DB::Connection.
    module ServerSessions
      # Returns the raw session id to hand to the browser.
      def self.open_session(conn, user_id, now, ttl)
        raw = Secure.hex(Secure.random_bytes(Token::BYTES))
        conn.execute(
          "INSERT INTO kaisatsu_sessions (digest, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
          [Token.digest_of(raw), user_id, now, now + ttl]
        )
        raw
      end

      # The user id of a live session, or "" when the id is unknown or
      # expired.
      def self.resolve_user(conn, raw, now)
        return "" if raw.bytesize != Token::BYTES * 2
        rows = conn.execute(
          "SELECT user_id FROM kaisatsu_sessions WHERE digest = ? AND expires_at > ?",
          [Token.digest_of(raw), now]
        )
        return "" if rows.empty?
        rows[0]["user_id"].to_s
      end

      def self.close_session(conn, raw)
        conn.execute("DELETE FROM kaisatsu_sessions WHERE digest = ?", [Token.digest_of(raw)])
        nil
      end

      # Ends every session of the user (sign out everywhere, password change).
      def self.close_all_for(conn, user_id)
        conn.execute("DELETE FROM kaisatsu_sessions WHERE user_id = ?", [user_id])
        nil
      end

      def self.purge_expired(conn, now)
        conn.execute("DELETE FROM kaisatsu_sessions WHERE expires_at <= ?", [now])
        nil
      end
    end
  end
end
