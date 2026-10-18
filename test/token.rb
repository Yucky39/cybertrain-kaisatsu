require_relative "support/harness"
require "cybertrain/kaisatsu"

include Cybertrain::Kaisatsu

test "a token is 64 hex characters and its digest is not the token" do
  t = Token.issue(1000, 3600)
  assert_equal 64, t.raw.bytesize
  assert_equal 64, t.digest.bytesize
  assert t.raw != t.digest
  assert_equal 4600, t.expires_at
end

test "the presented token matches its stored digest only" do
  t = Token.issue(0, 60)
  assert Token.matches?(t.raw, t.digest)
  assert !Token.matches?(t.raw + "0", t.digest)
  assert !Token.matches?("0" * 64, t.digest)
  assert !Token.matches?("", t.digest)
end

test "two tokens differ" do
  assert Token.issue(0, 60).raw != Token.issue(0, 60).raw
end

test "expiry is inclusive of the deadline" do
  assert !Token.expired?(100, 99)
  assert Token.expired?(100, 100)
  assert Token.expired?(100, 101)
end

test "secure equality is exact and length-aware" do
  assert Secure.equal?("abc", "abc")
  assert !Secure.equal?("abc", "abd")
  assert !Secure.equal?("abc", "abcd")
  assert_equal "00ff10", Secure.hex("\x00\xff\x10".b)
end

KaisatsuTest.run!
