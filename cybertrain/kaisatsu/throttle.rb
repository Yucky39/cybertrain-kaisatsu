require "digest"
require "cybertrain/kaisatsu/secure"

module Cybertrain
  module Kaisatsu
    # Fixed-window failure counters for sign-in attempts, kept in the
    # database (no process-wide lock on the request path: NOTES rule 57).
    # Keys are digested before they are stored.
    module Throttle
      def self.key_digest(key)
        Secure.hex(Digest::SHA256.digest(key))
      end

      # True when the key already has `limit` failures inside the window.
      def self.blocked?(conn, key, now, limit, window)
        rows = conn.execute(
          "SELECT window_start, failures FROM kaisatsu_attempts WHERE bucket = ?",
          [key_digest(key)]
        )
        return false if rows.empty?
        return false if now - rows[0]["window_start"] >= window
        rows[0]["failures"] >= limit
      end

      def self.note_failure(conn, key, now, window)
        conn.execute(
          "INSERT INTO kaisatsu_attempts (bucket, window_start, failures) VALUES (?, ?, 1) " \
          "ON CONFLICT(bucket) DO UPDATE SET " \
          "failures = CASE WHEN ? - window_start >= ? THEN 1 ELSE failures + 1 END, " \
          "window_start = CASE WHEN ? - window_start >= ? THEN ? ELSE window_start END",
          [key_digest(key), now, now, window, now, window, now]
        )
        nil
      end

      # Counts one attempt against the key and says whether it may go ahead:
      # the first `limit` attempts inside the window do, later ones do not.
      # For limits that count every try, not only the failures (sign-up).
      def self.hit(conn, key, now, limit, window)
        return false if blocked?(conn, key, now, limit, window)
        note_failure(conn, key, now, window)
        true
      end

      # Drops the counters whose window has ended: they no longer block anyone.
      def self.purge_expired(conn, now, window)
        conn.execute("DELETE FROM kaisatsu_attempts WHERE window_start <= ?", [now - window])
        nil
      end

      def self.clear(conn, key)
        conn.execute("DELETE FROM kaisatsu_attempts WHERE bucket = ?", [key_digest(key)])
        nil
      end
    end
  end
end
