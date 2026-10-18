require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/kaisatsu/full"

# Links SQLite through FFI: snapshot from the compiled binary.

K = Cybertrain::Kaisatsu
K::PasswordHash.iterations = 1000

class ResetDirectory < K::UserDirectory
  def initialize
    @hash = ""
  end

  def set_hash(value)
    @hash = value
    nil
  end

  def credentials_for(login)
    return K::Credentials.new(true, "1", @hash) if login == "taro@example.com"
    K::Credentials.missing
  end

  def store_password_hash(user_id, password_hash)
    @hash = password_hash
    nil
  end

  def email_for(user_id)
    user_id == "1" ? "taro@example.com" : ""
  end
end

class RecordingNotifier < K::Notifier
  def initialize
    @resets = 0
    @last_email = ""
    @last_link = ""
    @changed = 0
  end

  def send_password_reset(email, link)
    @resets += 1
    @last_email = email
    @last_link = link
    nil
  end

  def send_password_changed(email)
    @changed += 1
    nil
  end

  def resets
    @resets
  end

  def changed
    @changed
  end

  def last_email
    @last_email
  end

  def last_link
    @last_link
  end

  def last_token
    @last_link.split("/")[-1]
  end
end

PREFIX = "https://app.example.com/password/reset/"

def fresh_conn
  conn = Cybertrain::DB::Connection.new(":memory:")
  K::Schema.install(conn)
  conn
end

class World
  attr_reader :conn, :directory, :notifier, :auth, :reset

  def initialize
    @conn = fresh_conn
    @directory = ResetDirectory.new
    @directory.set_hash(K::PasswordHash.create("old good password"))
    @notifier = RecordingNotifier.new
    @auth = K::Authenticator.new(@directory)
    @reset = K::PasswordReset.new(@auth, @directory, @notifier, "https://app.example.com")
  end
end

test "a reset request for a known account sends one link to that address" do
  w = World.new
  w.reset.request_reset(w.conn, "  Taro@Example.com ", "10.0.0.1", 1000)
  assert_equal 1, w.notifier.resets
  assert_equal "taro@example.com", w.notifier.last_email
  assert w.notifier.last_link.start_with?(PREFIX)
  assert_equal 64, w.notifier.last_token.bytesize
  w.conn.close
end

test "an unknown account gets no mail and no sign of that" do
  w = World.new
  w.reset.request_reset(w.conn, "nobody@example.com", "10.0.0.1", 1000)
  assert_equal 0, w.notifier.resets
  w.conn.close
end

test "the link works once and sets the new password" do
  w = World.new
  w.reset.request_reset(w.conn, "taro@example.com", "", 1000)
  token = w.notifier.last_token
  assert w.reset.token_valid?(w.conn, token, 1100)
  out = w.reset.complete_reset(w.conn, token, "a brand new password", 1100)
  assert out.done?
  assert w.auth.login(w.conn, "taro@example.com", "a brand new password", "", 1101).ok?
  assert_equal "invalid", w.auth.login(w.conn, "taro@example.com", "old good password", "", 1102).status
  second = w.reset.complete_reset(w.conn, token, "yet another password", 1103)
  assert_equal "invalid_token", second.status
  assert_equal 1, w.notifier.changed
  w.conn.close
end

test "completing a reset ends every existing session" do
  w = World.new
  r = w.auth.login(w.conn, "taro@example.com", "old good password", "", 1000)
  assert r.ok?
  w.reset.request_reset(w.conn, "taro@example.com", "", 1001)
  w.reset.complete_reset(w.conn, w.notifier.last_token, "a brand new password", 1002)
  assert_equal "", K::ServerSessions.resolve_user(w.conn, r.session_id, 1003)
  w.conn.close
end

test "a weak password is refused without spending the link" do
  w = World.new
  w.reset.request_reset(w.conn, "taro@example.com", "", 1000)
  token = w.notifier.last_token
  weak = w.reset.complete_reset(w.conn, token, "short", 1001)
  assert_equal "weak_password", weak.status
  refute weak.message.empty?
  assert w.reset.token_valid?(w.conn, token, 1002)
  assert w.reset.complete_reset(w.conn, token, "a brand new password", 1003).done?
  w.conn.close
end

test "the link expires after an hour" do
  w = World.new
  w.reset.request_reset(w.conn, "taro@example.com", "", 1000)
  token = w.notifier.last_token
  refute w.reset.token_valid?(w.conn, token, 1000 + 3600)
  assert_equal "invalid_token", w.reset.complete_reset(w.conn, token, "a brand new password", 1000 + 3600).status
  w.conn.close
end

test "a forged or empty token is invalid" do
  w = World.new
  assert_equal "invalid_token", w.reset.complete_reset(w.conn, "f" * 64, "a brand new password", 1000).status
  assert_equal "invalid_token", w.reset.complete_reset(w.conn, "", "a brand new password", 1000).status
  refute w.reset.token_valid?(w.conn, "short", 1000)
  w.conn.close
end

test "a newer link voids the older one" do
  w = World.new
  w.reset.request_reset(w.conn, "taro@example.com", "", 1000)
  first = w.notifier.last_token
  w.reset.request_reset(w.conn, "taro@example.com", "", 1001)
  second = w.notifier.last_token
  refute w.reset.token_valid?(w.conn, first, 1002)
  assert w.reset.token_valid?(w.conn, second, 1002)
  w.conn.close
end

test "requests are limited per account, silently, and recover after the window" do
  w = World.new
  5.times { |i| w.reset.request_reset(w.conn, "taro@example.com", "", 1000 + i) }
  assert_equal 3, w.notifier.resets
  w.reset.request_reset(w.conn, "taro@example.com", "", 1000 + 3600 + 5)
  assert_equal 4, w.notifier.resets
  w.conn.close
end

test "one address cannot request resets for many accounts without limit" do
  w = World.new
  12.times { |i| w.reset.request_reset(w.conn, "user" + i.to_s + "@example.com", "10.9.9.9", 1000 + i) }
  w.reset.request_reset(w.conn, "taro@example.com", "10.9.9.9", 1100)
  assert_equal 0, w.notifier.resets
  w.reset.request_reset(w.conn, "taro@example.com", "10.1.1.1", 1101)
  assert_equal 1, w.notifier.resets
  w.conn.close
end

Cybertrain::Test.run!
