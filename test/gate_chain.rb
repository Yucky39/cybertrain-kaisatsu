require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/db"
require "cybertrain/middleware/session_store"
require "cybertrain/router"
require "cybertrain/kaisatsu/full"

# The real stack order, SessionStore -> Gate -> Router, driven through
# Test::Client the way a browser would (cookies round-trip). Links SQLite:
# snapshot from the compiled binary.

K = Cybertrain::Kaisatsu
K::PasswordHash.iterations = 1000
Cybertrain::DB.connect(":memory:")
Cybertrain::DB.with { |conn| K::Schema.install(conn) }

class OneUser < K::UserDirectory
  def initialize(stored)
    @stored_hash = stored
  end

  def credentials_for(login)
    return K::Credentials.new(true, "1", @stored_hash) if login == "taro@example.com"
    K::Credentials.missing
  end

  def store_password_hash(user_id, password_hash)
    @stored_hash = password_hash
    nil
  end
end

STORED_HASH = "$pbkdf2-sha256$i=1000$3ateiw3psezi7z4VqKJJ4A$0fxgyNw5F/6jXMTM3meFBpU2ZrIVHI7Qnp8pUeWmdsI"

ONE_USER = OneUser.new(STORED_HASH)
AUTH = K::Authenticator.new(ONE_USER)

# DB.with is called from plain methods, not from inside a route block: a
# yielding method with a rescue called from a block nested in a block does not
# compile (cybertrain NOTES rules 32, 45).
def handle_login(ctx)
  r = login_result(ctx)
  if r.ok?
    K::Gate.sign_in(ctx, r.session_id, r.user_id)
    ctx.response.body = "welcome"
  else
    ctx.response.status = 401
    ctx.response.body = r.status
  end
  nil
end

# The result is declared first and assigned in the block: the value of a
# DB.with block is untyped, and a method call on it fails at run time on Spinel
# 2026.10.26.7019.
def login_result(ctx)
  result = K::LoginResult.new("none", "", "")
  Cybertrain::DB.with do |conn|
    result = AUTH.login(conn, ctx.params["email"].to_s, ctx.params["password"].to_s, "", Time.now.to_i)
  end
  result
end

def handle_logout(ctx)
  Cybertrain::DB.with { |conn| K::Gate.sign_out(ctx, conn) }
  ctx.response.body = "bye"
  nil
end

def handle_me(ctx)
  ctx.response.body = K::Gate.signed_in?(ctx) ? "user " + K::Gate.user_id(ctx) : "anonymous"
  nil
end

def handle_private(ctx)
  ctx.response.body = "secret" unless K::Gate.require_login(ctx, "/login")
  nil
end

def build_app
  router = Cybertrain::Router.new
  router.get("/me") { |ctx| handle_me(ctx) }
  router.get("/private") { |ctx| handle_private(ctx) }
  router.post("/login") { |ctx| handle_login(ctx) }
  router.post("/logout") { |ctx| handle_logout(ctx) }
  gate = K::Gate.new(router)
  Cybertrain::SessionStore.new(gate, secret: "gate-chain-secret")
end

app = build_app

def sign_in(client)
  client.post("/login", { "email" => "taro@example.com", "password" => "correct horse battery" })
end

test "an anonymous visitor is turned away from a private page" do
  client = Cybertrain::Test::Client.new(app)
  assert_equal "anonymous", client.get("/me").body
  res = client.get("/private")
  assert_equal 302, res.status
  assert_equal "/login", res.header("location")
end

test "signing in makes the next requests signed in" do
  client = Cybertrain::Test::Client.new(app)
  res = sign_in(client)
  assert_equal "welcome", res.body
  assert_equal "user 1", client.get("/me").body
  assert_equal "secret", client.get("/private").body
end

test "a failed sign-in leaves the visitor anonymous" do
  client = Cybertrain::Test::Client.new(app)
  res = client.post("/login", { "email" => "taro@example.com", "password" => "wrong password!" })
  assert_equal 401, res.status
  assert_equal "invalid", res.body
  assert_equal "anonymous", client.get("/me").body
end

test "signing out ends the session on the server" do
  client = Cybertrain::Test::Client.new(app)
  cookie_while_signed_in = sign_in(client).cookies[0].split(";")[0]
  client.post("/logout")
  assert_equal "anonymous", client.get("/me").body
  # Replaying the old cookie must not work: the server session is gone.
  replay = Cybertrain::Test::Client.new(app)
  assert_equal "anonymous", replay.request("GET", "/me", "", { "cookie" => cookie_while_signed_in }).body
end

test "ending every session of the user signs out a second browser at once" do
  one = Cybertrain::Test::Client.new(app)
  two = Cybertrain::Test::Client.new(app)
  sign_in(one)
  sign_in(two)
  assert_equal "user 1", two.get("/me").body
  Cybertrain::DB.with { |conn| K::ServerSessions.close_all_for(conn, "1") }
  assert_equal "anonymous", one.get("/me").body
  assert_equal "anonymous", two.get("/me").body
end

test "a forged user id in the cookie session grants nothing" do
  client = Cybertrain::Test::Client.new(app)
  sess = Cybertrain::Session.new({ "_kaisatsu_uid" => "1" })
  forged = Cybertrain::Session.dump(sess, "gate-chain-secret")
  res = client.request("GET", "/me", "", { "cookie" => "_cybertrain_session=" + forged })
  assert_equal "anonymous", res.body
end

test "hashing a password while the app is serving does not disturb routing" do
  stored = K::PasswordHash.create("another good password")
  assert K::PasswordHash.verify("another good password", stored)
  client = Cybertrain::Test::Client.new(app)
  assert_equal "anonymous", client.get("/me").body
  assert_equal "welcome", sign_in(client).body
  assert_equal "user 1", client.get("/me").body
end

Cybertrain::Test.run!
