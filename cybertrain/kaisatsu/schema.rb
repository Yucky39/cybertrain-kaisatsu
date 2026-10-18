module Cybertrain
  module Kaisatsu
    # The tables Kaisatsu keeps. The application owns its users table and
    # supplies it through a UserDirectory; these hold only what Kaisatsu
    # itself needs. Tokens and session ids are stored as SHA-256 digests,
    # throttle keys as digests too (no e-mail addresses or IPs in the clear).
    module Schema
      STATEMENTS = [
        "CREATE TABLE IF NOT EXISTS kaisatsu_sessions (" \
        "digest TEXT PRIMARY KEY, user_id TEXT NOT NULL, " \
        "created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS index_kaisatsu_sessions_on_user_id ON kaisatsu_sessions (user_id)",
        "CREATE TABLE IF NOT EXISTS kaisatsu_tokens (" \
        "digest TEXT PRIMARY KEY, user_id TEXT NOT NULL, purpose TEXT NOT NULL, " \
        "expires_at INTEGER NOT NULL, used_at INTEGER)",
        "CREATE INDEX IF NOT EXISTS index_kaisatsu_tokens_on_user_id ON kaisatsu_tokens (user_id)",
        "CREATE TABLE IF NOT EXISTS kaisatsu_attempts (" \
        "key TEXT PRIMARY KEY, window_start INTEGER NOT NULL, failures INTEGER NOT NULL)"
      ]

      # conn is a Cybertrain::DB::Connection. Idempotent.
      def self.install(conn)
        STATEMENTS.each { |sql| conn.exec_script(sql) }
        nil
      end
    end
  end
end
