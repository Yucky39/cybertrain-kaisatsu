require "cybertrain/kaisatsu/token"

module Cybertrain
  module Kaisatsu
    # One-time tokens (password reset, e-mail confirmation) in the database.
    # Only the digest is stored. consume_token is a single UPDATE, so two
    # concurrent requests with the same token cannot both succeed.
    module TokenStore
      PURPOSE_RESET = "password_reset"
      PURPOSE_VERIFY = "email_verify"
      PURPOSE_CHANGE = "email_change"
      PURPOSE_REVERT = "email_revert"

      # Issues a token for the user and returns the raw value to send out.
      # An earlier unused token of the same purpose is invalidated.
      def self.save_token(conn, user_id, purpose, now, ttl)
        conn.execute("DELETE FROM kaisatsu_tokens WHERE user_id = ? AND purpose = ?", [user_id, purpose])
        token = Token.issue(now, ttl)
        conn.execute(
          "INSERT INTO kaisatsu_tokens (digest, user_id, purpose, expires_at) VALUES (?, ?, ?, ?)",
          [token.digest, user_id, purpose, token.expires_at]
        )
        token.raw
      end

      # The user id the token belongs to, or "" when it is unknown, of another
      # purpose, expired or already used. A valid token is spent by the call.
      def self.consume_token(conn, raw, purpose, now)
        return "" if raw.bytesize != Token::BYTES * 2
        digest = Token.digest_of(raw)
        conn.execute(
          "UPDATE kaisatsu_tokens SET used_at = ? WHERE digest = ? AND purpose = ? " \
          "AND used_at IS NULL AND expires_at > ?",
          [now, digest, purpose, now]
        )
        return "" if conn.changes != 1
        rows = conn.execute("SELECT user_id FROM kaisatsu_tokens WHERE digest = ?", [digest])
        rows.empty? ? "" : rows[0]["user_id"].to_s
      end

      # The user id a token would belong to, without spending it ("" when it
      # is unknown, of another purpose, expired or already used). For showing
      # the "choose a new password" form before the token is used.
      def self.peek_token(conn, raw, purpose, now)
        return "" if raw.bytesize != Token::BYTES * 2
        rows = conn.execute(
          "SELECT user_id FROM kaisatsu_tokens WHERE digest = ? AND purpose = ? " \
          "AND used_at IS NULL AND expires_at > ?",
          [Token.digest_of(raw), purpose, now]
        )
        rows.empty? ? "" : rows[0]["user_id"].to_s
      end

      # Voids the user's outstanding tokens of one purpose.
      def self.void_purpose(conn, user_id, purpose)
        conn.execute("DELETE FROM kaisatsu_tokens WHERE user_id = ? AND purpose = ?", [user_id, purpose])
        nil
      end

      # Voids every outstanding token of the user (after the sign-in address
      # changed: links mailed to the old address must stop working).
      def self.void_tokens(conn, user_id)
        conn.execute("DELETE FROM kaisatsu_tokens WHERE user_id = ?", [user_id])
        nil
      end

      def self.purge_expired_tokens(conn, now)
        conn.execute("DELETE FROM kaisatsu_tokens WHERE expires_at <= ? OR used_at IS NOT NULL", [now])
        nil
      end
    end
  end
end
