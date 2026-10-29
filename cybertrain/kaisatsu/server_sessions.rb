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
      # A session never lives longer than this from its start, however often it
      # is used (the sliding expiry below stops there).
      ABSOLUTE_TTL = 1_209_600
      # A session ends this long after its last request.
      IDLE_TTL = 604_800
      # The expiry is moved only when this much of the idle period has gone, so
      # a busy session costs a write once an hour, not on every request.
      SLIDE_AFTER = 3600

      # Returns the raw session id to hand to the browser. ttl is how long it
      # lasts from now; resolve_user slides it by IDLE_TTL on use, up to
      # ABSOLUTE_TTL from the start.
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
        digest = Token.digest_of(raw)
        rows = conn.execute(
          "SELECT user_id, created_at, expires_at FROM kaisatsu_sessions WHERE digest = ? AND expires_at > ?",
          [digest, now]
        )
        return "" if rows.empty?
        slide(conn, digest, rows[0]["created_at"], rows[0]["expires_at"], now)
        rows[0]["user_id"].to_s
      end

      # Moves the expiry of a used session to IDLE_TTL from now, never past
      # created_at + ABSOLUTE_TTL.
      def self.slide(conn, digest, created_at, expires_at, now)
        wanted = now + IDLE_TTL
        cap = created_at + ABSOLUTE_TTL
        wanted = cap if wanted > cap
        return nil if wanted - expires_at < SLIDE_AFTER
        conn.execute("UPDATE kaisatsu_sessions SET expires_at = ? WHERE digest = ?", [wanted, digest])
        nil
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
