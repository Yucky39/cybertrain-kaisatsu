require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/kaisatsu/full"

# Links SQLite through FFI, so it runs only under Spinel: the snapshot comes
# from the compiled binary (cybertrain NOTES rule 23).

K = Cybertrain::Kaisatsu

def fresh_conn
  conn = Cybertrain::DB::Connection.new(":memory:")
  K::Schema.install(conn)
  conn
end

test "Schema.install is idempotent" do
  conn = fresh_conn
  K::Schema.install(conn)
  rows = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'kaisatsu_%' ORDER BY name")
  assert_equal 3, rows.size
  conn.close
end

test "a server session resolves to its user until it expires" do
  conn = fresh_conn
  sid = K::ServerSessions.open_session(conn, "42", 1000, 100)
  assert_equal 64, sid.bytesize
  assert_equal "42", K::ServerSessions.resolve_user(conn, sid, 1050)
  assert_equal "", K::ServerSessions.resolve_user(conn, sid, 1100)
  assert_equal "", K::ServerSessions.resolve_user(conn, "0" * 64, 1050)
  assert_equal "", K::ServerSessions.resolve_user(conn, "short", 1050)
  conn.close
end

test "the session id itself is never stored" do
  conn = fresh_conn
  sid = K::ServerSessions.open_session(conn, "42", 1000, 100)
  rows = conn.execute("SELECT digest FROM kaisatsu_sessions")
  assert_equal 1, rows.size
  refute rows[0]["digest"] == sid
  assert_equal K::Token.digest_of(sid), rows[0]["digest"]
  conn.close
end

test "closing one session leaves the others, closing all ends every one" do
  conn = fresh_conn
  a = K::ServerSessions.open_session(conn, "42", 1000, 100)
  b = K::ServerSessions.open_session(conn, "42", 1000, 100)
  other = K::ServerSessions.open_session(conn, "7", 1000, 100)
  K::ServerSessions.close_session(conn, a)
  assert_equal "", K::ServerSessions.resolve_user(conn, a, 1010)
  assert_equal "42", K::ServerSessions.resolve_user(conn, b, 1010)
  K::ServerSessions.close_all_for(conn, "42")
  assert_equal "", K::ServerSessions.resolve_user(conn, b, 1010)
  assert_equal "7", K::ServerSessions.resolve_user(conn, other, 1010)
  conn.close
end

test "a token is spent by its first use only" do
  conn = fresh_conn
  raw = K::TokenStore.save_token(conn, "42", K::TokenStore::PURPOSE_RESET, 1000, 600)
  assert_equal "42", K::TokenStore.consume_token(conn, raw, K::TokenStore::PURPOSE_RESET, 1100)
  assert_equal "", K::TokenStore.consume_token(conn, raw, K::TokenStore::PURPOSE_RESET, 1101)
  conn.close
end

test "a token is refused after expiry, for another purpose, or when forged" do
  conn = fresh_conn
  raw = K::TokenStore.save_token(conn, "42", K::TokenStore::PURPOSE_RESET, 1000, 600)
  assert_equal "", K::TokenStore.consume_token(conn, raw, K::TokenStore::PURPOSE_VERIFY, 1100)
  assert_equal "", K::TokenStore.consume_token(conn, "f" * 64, K::TokenStore::PURPOSE_RESET, 1100)
  assert_equal "", K::TokenStore.consume_token(conn, raw, K::TokenStore::PURPOSE_RESET, 1600)
  conn.close
end

test "issuing a new token voids the earlier one of the same purpose" do
  conn = fresh_conn
  first = K::TokenStore.save_token(conn, "42", K::TokenStore::PURPOSE_RESET, 1000, 600)
  second = K::TokenStore.save_token(conn, "42", K::TokenStore::PURPOSE_RESET, 1001, 600)
  assert_equal "", K::TokenStore.consume_token(conn, first, K::TokenStore::PURPOSE_RESET, 1100)
  assert_equal "42", K::TokenStore.consume_token(conn, second, K::TokenStore::PURPOSE_RESET, 1100)
  conn.close
end

test "throttle blocks at the limit and releases after the window" do
  conn = fresh_conn
  refute K::Throttle.blocked?(conn, "account:a@example.com", 1000, 3, 900)
  K::Throttle.note_failure(conn, "account:a@example.com", 1000, 900)
  K::Throttle.note_failure(conn, "account:a@example.com", 1010, 900)
  refute K::Throttle.blocked?(conn, "account:a@example.com", 1020, 3, 900)
  K::Throttle.note_failure(conn, "account:a@example.com", 1020, 900)
  assert K::Throttle.blocked?(conn, "account:a@example.com", 1030, 3, 900)
  refute K::Throttle.blocked?(conn, "account:b@example.com", 1030, 3, 900)
  refute K::Throttle.blocked?(conn, "account:a@example.com", 1900, 3, 900)
  conn.close
end

test "a failure after the window starts a new count; clear forgets" do
  conn = fresh_conn
  K::Throttle.note_failure(conn, "k", 1000, 900)
  K::Throttle.note_failure(conn, "k", 1001, 900)
  K::Throttle.note_failure(conn, "k", 2000, 900)
  refute K::Throttle.blocked?(conn, "k", 2001, 2, 900)
  K::Throttle.note_failure(conn, "k", 2002, 900)
  assert K::Throttle.blocked?(conn, "k", 2003, 2, 900)
  K::Throttle.clear(conn, "k")
  refute K::Throttle.blocked?(conn, "k", 2004, 2, 900)
  conn.close
end

test "throttle keys are stored as digests" do
  conn = fresh_conn
  K::Throttle.note_failure(conn, "account:a@example.com", 1000, 900)
  rows = conn.execute("SELECT bucket FROM kaisatsu_attempts")
  refute rows[0]["bucket"].include?("example")
  conn.close
end

Cybertrain::Test.run!
