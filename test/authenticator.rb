require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/kaisatsu/full"

# Links SQLite through FFI: snapshot from the compiled binary.

K = Cybertrain::Kaisatsu
K::PasswordHash.iterations = 1000

class MemoryDirectory < K::UserDirectory
  def initialize
    @ids = ["1"]
    @ids.clear
    @logins = ["a"]
    @logins.clear
    @hashes = ["h"]
    @hashes.clear
    @stores = 0
  end

  def add(user_id, login, password_hash)
    @ids << user_id
    @logins << login
    @hashes << password_hash
    nil
  end

  def credentials_for(login)
    i = 0
    while i < @logins.length
      return K::Credentials.new(true, @ids[i], @hashes[i]) if @logins[i] == login
      i += 1
    end
    K::Credentials.missing
  end

  def store_password_hash(user_id, password_hash)
    i = 0
    while i < @ids.length
      @hashes[i] = password_hash if @ids[i] == user_id
      i += 1
    end
    @stores += 1
    nil
  end

  def stores
    @stores
  end

  def hash_of(user_id)
    i = 0
    while i < @ids.length
      return @hashes[i] if @ids[i] == user_id
      i += 1
    end
    ""
  end
end

def fresh_conn
  conn = Cybertrain::DB::Connection.new(":memory:")
  K::Schema.install(conn)
  conn
end

def directory
  d = MemoryDirectory.new
  d.add("1", "taro@example.com", K::PasswordHash.create("correct horse battery"))
  d
end

test "the right password opens a session for the user" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  r = auth.login(conn, "taro@example.com", "correct horse battery", "10.0.0.1", 1000)
  assert r.ok?
  assert_equal "1", r.user_id
  assert_equal "1", K::ServerSessions.resolve_user(conn, r.session_id, 1001)
  conn.close
end

test "the login name is trimmed and case-insensitive" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  r = auth.login(conn, "  Taro@Example.COM ", "correct horse battery", "", 1000)
  assert r.ok?
  conn.close
end

test "a wrong password and an unknown account get the same answer" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  wrong = auth.login(conn, "taro@example.com", "not the password", "", 1000)
  unknown = auth.login(conn, "nobody@example.com", "not the password", "", 1000)
  assert_equal "invalid", wrong.status
  assert_equal "invalid", unknown.status
  assert_equal "", wrong.session_id
  assert_equal "", unknown.session_id
  conn.close
end

test "repeated failures throttle the account, even for the right password" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  5.times { auth.login(conn, "taro@example.com", "bad password!", "", 1000) }
  r = auth.login(conn, "taro@example.com", "correct horse battery", "", 1001)
  assert_equal "throttled", r.status
  later = auth.login(conn, "taro@example.com", "correct horse battery", "", 2000)
  assert later.ok?
  conn.close
end

test "a successful login resets the account's failure count" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  4.times { auth.login(conn, "taro@example.com", "bad password!", "", 1000) }
  assert auth.login(conn, "taro@example.com", "correct horse battery", "", 1001).ok?
  4.times { auth.login(conn, "taro@example.com", "bad password!", "", 1002) }
  assert auth.login(conn, "taro@example.com", "correct horse battery", "", 1003).ok?
  conn.close
end

test "one address cannot lock out every account: the ip limit is higher" do
  conn = fresh_conn
  auth = K::Authenticator.new(directory)
  6.times { |i| auth.login(conn, "user" + i.to_s + "@example.com", "bad password!", "10.0.0.9", 1000) }
  assert auth.login(conn, "taro@example.com", "correct horse battery", "10.0.0.9", 1001).ok?
  conn.close
end

test "an old hash is replaced after a successful login" do
  conn = fresh_conn
  d = directory
  before = d.hash_of("1")
  K::PasswordHash.iterations = 2000
  K::Authenticator.new(d).login(conn, "taro@example.com", "correct horse battery", "", 1000)
  assert_equal 1, d.stores
  refute d.hash_of("1") == before
  assert_equal "i=2000", d.hash_of("1").split("$")[2]
  K::PasswordHash.iterations = 1000
  conn.close
end

test "changing the password ends every session and the old password stops working" do
  conn = fresh_conn
  d = directory
  auth = K::Authenticator.new(d)
  r = auth.login(conn, "taro@example.com", "correct horse battery", "", 1000)
  assert_equal "", auth.change_password(conn, "1", "a brand new password")
  assert_equal "", K::ServerSessions.resolve_user(conn, r.session_id, 1001)
  assert_equal "invalid", auth.login(conn, "taro@example.com", "correct horse battery", "", 1002).status
  assert auth.login(conn, "taro@example.com", "a brand new password", "", 1003).ok?
  conn.close
end

test "a password that breaks the policy is refused and nothing changes" do
  conn = fresh_conn
  d = directory
  before = d.hash_of("1")
  err = K::Authenticator.new(d).change_password(conn, "1", "short")
  refute err.empty?
  assert_equal before, d.hash_of("1")
  conn.close
end

Cybertrain::Test.run!
