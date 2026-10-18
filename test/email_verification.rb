require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/kaisatsu/full"

# Links SQLite through FFI: snapshot from the compiled binary.

K = Cybertrain::Kaisatsu

class VerifyDirectory < K::UserDirectory
  def initialize
    @verified = false
    @marks = 0
  end

  def credentials_for(login)
    return K::Credentials.new(true, "1", "unused") if login == "taro@example.com"
    K::Credentials.missing
  end

  def email_verified?(user_id)
    @verified
  end

  def mark_email_verified(user_id)
    @verified = true
    @marks += 1
    nil
  end

  def marks
    @marks
  end

  def verified
    @verified
  end
end

class VerifyNotifier < K::Notifier
  def initialize
    @sent = 0
    @last_email = ""
    @last_link = ""
  end

  def send_email_verification(email, link)
    @sent += 1
    @last_email = email
    @last_link = link
    nil
  end

  def sent
    @sent
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

def fresh_conn
  conn = Cybertrain::DB::Connection.new(":memory:")
  K::Schema.install(conn)
  conn
end

class Setup
  attr_reader :conn, :directory, :notifier, :verification

  def initialize
    @conn = fresh_conn
    @directory = VerifyDirectory.new
    @notifier = VerifyNotifier.new
    @verification = K::EmailVerification.new(@directory, @notifier, "https://app.example.com")
  end
end

test "a request for an unconfirmed account sends the link to that address" do
  w = Setup.new
  w.verification.request_verification(w.conn, " Taro@Example.com ", "10.0.0.1", 1000)
  assert_equal 1, w.notifier.sent
  assert_equal "taro@example.com", w.notifier.last_email
  assert w.notifier.last_link.start_with?("https://app.example.com/email/verify/")
  assert_equal 64, w.notifier.last_token.bytesize
  w.conn.close
end

test "an unknown account, and one that is already confirmed, get no mail" do
  w = Setup.new
  w.verification.request_verification(w.conn, "nobody@example.com", "", 1000)
  assert_equal 0, w.notifier.sent
  w.directory.mark_email_verified("1")
  w.verification.request_verification(w.conn, "taro@example.com", "", 1001)
  assert_equal 0, w.notifier.sent
  w.conn.close
end

test "opening the link does not confirm; the button does, once" do
  w = Setup.new
  w.verification.request_verification(w.conn, "taro@example.com", "", 1000)
  token = w.notifier.last_token
  assert w.verification.token_valid?(w.conn, token, 1100)
  refute w.directory.verified
  assert w.verification.complete_verification(w.conn, token, 1101).done?
  assert w.directory.verified
  assert_equal "invalid_token", w.verification.complete_verification(w.conn, token, 1102).status
  assert_equal 1, w.directory.marks
  w.conn.close
end

test "the link expires after three days" do
  w = Setup.new
  w.verification.request_verification(w.conn, "taro@example.com", "", 1000)
  token = w.notifier.last_token
  refute w.verification.token_valid?(w.conn, token, 1000 + 259_200)
  assert_equal "invalid_token", w.verification.complete_verification(w.conn, token, 1000 + 259_200).status
  refute w.directory.verified
  w.conn.close
end

test "a forged or empty token confirms nothing" do
  w = Setup.new
  assert_equal "invalid_token", w.verification.complete_verification(w.conn, "f" * 64, 1000).status
  assert_equal "invalid_token", w.verification.complete_verification(w.conn, "", 1000).status
  refute w.directory.verified
  w.conn.close
end

test "a reset token cannot confirm an address, nor the other way round" do
  w = Setup.new
  reset_raw = K::TokenStore.save_token(w.conn, "1", K::TokenStore::PURPOSE_RESET, 1000, 600)
  assert_equal "invalid_token", w.verification.complete_verification(w.conn, reset_raw, 1001).status
  w.verification.request_verification(w.conn, "taro@example.com", "", 1002)
  assert_equal "", K::TokenStore.consume_token(w.conn, w.notifier.last_token, K::TokenStore::PURPOSE_RESET, 1003)
  w.conn.close
end

test "a newer link voids the older one" do
  w = Setup.new
  w.verification.request_verification(w.conn, "taro@example.com", "", 1000)
  first = w.notifier.last_token
  w.verification.request_verification(w.conn, "taro@example.com", "", 1001)
  refute w.verification.token_valid?(w.conn, first, 1002)
  assert w.verification.token_valid?(w.conn, w.notifier.last_token, 1002)
  w.conn.close
end

test "requests are limited per account and recover after the window" do
  w = Setup.new
  5.times { |i| w.verification.request_verification(w.conn, "taro@example.com", "", 1000 + i) }
  assert_equal 3, w.notifier.sent
  w.verification.request_verification(w.conn, "taro@example.com", "", 1000 + 3600 + 5)
  assert_equal 4, w.notifier.sent
  w.conn.close
end

Cybertrain::Test.run!
