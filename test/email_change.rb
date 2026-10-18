require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/kaisatsu/full"

# Links SQLite through FFI: snapshot from the compiled binary.

K = Cybertrain::Kaisatsu
K::PasswordHash.iterations = 1000

class AccountBook < K::UserDirectory
  def initialize
    @emails = ["a"]
    @emails.clear
    @pending = ["a"]
    @pending.clear
    @verified = [true]
    @verified.clear
    @hashes = ["a"]
    @hashes.clear
  end

  def add(email, password, verified)
    @emails << email
    @pending << ""
    @verified << verified
    @hashes << K::PasswordHash.create(password)
    nil
  end

  def slot(user_id)
    i = user_id.to_i - 1
    i < @emails.length ? i : -1
  end

  def credentials_for(login)
    i = 0
    while i < @emails.length
      return K::Credentials.new(true, (i + 1).to_s, @hashes[i]) if @emails[i] == login
      i += 1
    end
    K::Credentials.missing
  end

  def email_for(user_id)
    i = slot(user_id)
    i < 0 ? "" : @emails[i]
  end

  def email_verified?(user_id)
    i = slot(user_id)
    i >= 0 && @verified[i]
  end

  def email_taken?(email, except_user_id)
    i = 0
    while i < @emails.length
      return true if @emails[i] == email && (i + 1).to_s != except_user_id
      i += 1
    end
    false
  end

  def begin_email_change(user_id, new_email)
    @pending[slot(user_id)] = new_email
    nil
  end

  def pending_email(user_id)
    i = slot(user_id)
    i < 0 ? "" : @pending[i]
  end

  def apply_email_change(user_id)
    i = slot(user_id)
    return false if i < 0 || @pending[i].empty?
    return false if email_taken?(@pending[i], user_id)
    @emails[i] = @pending[i]
    @pending[i] = ""
    @verified[i] = true
    true
  end

  def store_password_hash(user_id, password_hash)
    @hashes[slot(user_id)] = password_hash
    nil
  end
end

class ChangeNotifier < K::Notifier
  def initialize
    @log = ["x"]
    @log.clear
  end

  def send_email_change_link(new_email, link)
    @log << ("link:" + new_email + ":" + link.split("/")[-1])
    nil
  end

  def send_email_change_requested(old_email, new_email)
    @log << ("requested:" + old_email + ":" + new_email)
    nil
  end

  def send_email_changed(old_email, new_email)
    @log << ("changed:" + old_email + ":" + new_email)
    nil
  end

  def entries
    @log
  end

  def count_of(kind)
    n = 0
    @log.each { |e| n += 1 if e.start_with?(kind + ":") }
    n
  end

  def last_token
    last = ""
    @log.each { |e| last = e.split(":")[2] if e.start_with?("link:") }
    last
  end
end

def fresh_conn
  conn = Cybertrain::DB::Connection.new(":memory:")
  K::Schema.install(conn)
  conn
end

class Case
  attr_reader :conn, :book, :notifier, :change, :auth

  def initialize
    @conn = fresh_conn
    @book = AccountBook.new
    @book.add("taro@example.com", "old good password", true)
    @book.add("hanako@example.com", "other good password", true)
    @notifier = ChangeNotifier.new
    @change = K::EmailChange.new(@book, @notifier, "https://app.example.com")
    @auth = K::Authenticator.new(@book)
  end
end

test "a request mails a link to the NEW address and a notice to the old one" do
  c = Case.new
  out = c.change.request_change(c.conn, "1", "  New@Example.com ", "old good password", 1000)
  assert out.accepted?
  assert_equal 1, c.notifier.count_of("link")
  assert_equal 1, c.notifier.count_of("requested")
  assert c.notifier.entries[0].start_with?("link:new@example.com:")
  assert_equal "requested:taro@example.com:new@example.com", c.notifier.entries[1]
  assert_equal "taro@example.com", c.book.email_for("1")
  c.conn.close
end

test "the address changes only when the button is pressed, once" do
  c = Case.new
  c.change.request_change(c.conn, "1", "new@example.com", "old good password", 1000)
  token = c.notifier.last_token
  assert c.change.token_valid?(c.conn, token, 1100)
  assert_equal "taro@example.com", c.book.email_for("1")
  assert c.change.complete_change(c.conn, token, 1101).done?
  assert_equal "new@example.com", c.book.email_for("1")
  assert c.book.email_verified?("1")
  assert_equal "invalid_token", c.change.complete_change(c.conn, token, 1102).status
  assert_equal 1, c.notifier.count_of("changed")
  assert_equal "changed:taro@example.com:new@example.com", c.notifier.entries[-1]
  c.conn.close
end

test "the new address signs in and the old one no longer does" do
  c = Case.new
  c.change.request_change(c.conn, "1", "new@example.com", "old good password", 1000)
  c.change.complete_change(c.conn, c.notifier.last_token, 1001)
  assert c.auth.login(c.conn, "new@example.com", "old good password", "", 1002).ok?
  assert_equal "invalid", c.auth.login(c.conn, "taro@example.com", "old good password", "", 1003).status
  c.conn.close
end

test "changing the address ends every session and voids older links" do
  c = Case.new
  r = c.auth.login(c.conn, "taro@example.com", "old good password", "", 1000)
  stale = K::TokenStore.save_token(c.conn, "1", K::TokenStore::PURPOSE_RESET, 1000, 3600)
  c.change.request_change(c.conn, "1", "new@example.com", "old good password", 1001)
  c.change.complete_change(c.conn, c.notifier.last_token, 1002)
  assert_equal "", K::ServerSessions.resolve_user(c.conn, r.session_id, 1003)
  assert_equal "", K::TokenStore.consume_token(c.conn, stale, K::TokenStore::PURPOSE_RESET, 1003)
  c.conn.close
end

test "a wrong password changes nothing, sends nothing, and counts against sign-in" do
  c = Case.new
  out = c.change.request_change(c.conn, "1", "new@example.com", "not the password", 1000)
  assert_equal "wrong_password", out.status
  assert_equal 0, c.notifier.entries.length
  4.times { |i| c.change.request_change(c.conn, "1", "new@example.com", "still wrong!", 1001 + i) }
  assert_equal "throttled", c.change.request_change(c.conn, "1", "new@example.com", "old good password", 1010).status
  c.conn.close
end

test "an address that is already taken looks exactly like success, and mails nothing" do
  c = Case.new
  out = c.change.request_change(c.conn, "1", "hanako@example.com", "old good password", 1000)
  assert out.accepted?
  assert_equal 0, c.notifier.entries.length
  assert_equal "", c.book.pending_email("1")
  c.conn.close
end

test "if the address is taken before the button is pressed, nothing changes" do
  c = Case.new
  c.change.request_change(c.conn, "1", "new@example.com", "old good password", 1000)
  token = c.notifier.last_token
  c.book.begin_email_change("2", "new@example.com")
  c.book.apply_email_change("2")
  assert_equal "taken", c.change.complete_change(c.conn, token, 1001).status
  assert_equal "taro@example.com", c.book.email_for("1")
  c.conn.close
end

test "malformed or unchanged addresses are refused before the password is asked for" do
  c = Case.new
  ["", "nobody", "@example.com", "a@", "a@b@c", "a b@example.com", "taro@example.com"].each do |bad|
    assert_equal "invalid_email", c.change.request_change(c.conn, "1", bad, "old good password", 1000).status
  end
  assert_equal 0, c.notifier.entries.length
  c.conn.close
end

test "the old address is told only if it had been confirmed" do
  c = Case.new
  c.book.add("fresh@example.com", "fresh good password", false)
  c.change.request_change(c.conn, "3", "next@example.com", "fresh good password", 1000)
  assert_equal 1, c.notifier.count_of("link")
  assert_equal 0, c.notifier.count_of("requested")
  c.conn.close
end

test "the link expires after a day, and a newer request voids the older link" do
  c = Case.new
  c.change.request_change(c.conn, "1", "one@example.com", "old good password", 1000)
  first = c.notifier.last_token
  c.change.request_change(c.conn, "1", "two@example.com", "old good password", 1001)
  second = c.notifier.last_token
  refute c.change.token_valid?(c.conn, first, 1002)
  assert c.change.token_valid?(c.conn, second, 1002)
  refute c.change.token_valid?(c.conn, second, 1001 + 86_400)
  assert_equal "invalid_token", c.change.complete_change(c.conn, second, 1001 + 86_400).status
  assert_equal "taro@example.com", c.book.email_for("1")
  c.conn.close
end

test "a forged token, or a verification token, changes nothing" do
  c = Case.new
  assert_equal "invalid_token", c.change.complete_change(c.conn, "f" * 64, 1000).status
  other = K::TokenStore.save_token(c.conn, "1", K::TokenStore::PURPOSE_VERIFY, 1000, 3600)
  assert_equal "invalid_token", c.change.complete_change(c.conn, other, 1001).status
  c.conn.close
end

Cybertrain::Test.run!
