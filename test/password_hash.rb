require_relative "support/harness"
require "cybertrain/kaisatsu"

include Cybertrain::Kaisatsu

PasswordHash.iterations = 1000

test "a created hash verifies the right password only" do
  stored = PasswordHash.create("correct horse battery")
  assert PasswordHash.verify("correct horse battery", stored)
  assert !PasswordHash.verify("correct horse batterx", stored)
  assert !PasswordHash.verify("", stored)
end

test "the stored form carries its parameters" do
  stored = PasswordHash.create("correct horse battery")
  parts = stored.split("$")
  assert_equal 5, parts.length
  assert_equal "pbkdf2-sha256", parts[1]
  assert_equal "i=1000", parts[2]
  assert !stored.include?("=" + "=")
end

test "two hashes of the same password differ (random salt)" do
  a = PasswordHash.create("correct horse battery")
  b = PasswordHash.create("correct horse battery")
  assert a != b
  assert PasswordHash.verify("correct horse battery", a)
  assert PasswordHash.verify("correct horse battery", b)
end

test "non-ASCII passwords work" do
  stored = PasswordHash.create("パスワードは長いほうが安全です")
  assert PasswordHash.verify("パスワードは長いほうが安全です", stored)
  assert !PasswordHash.verify("パスワードは長いほうが安全でず", stored)
end

test "malformed stored hashes never verify and never raise" do
  bad = ["", "plaintext", "$", "$pbkdf2-sha256$", "$pbkdf2-sha256$i=1000$AAAA",
         "$argon2id$i=1000$AAAA$AAAA", "$pbkdf2-sha256$i=abc$AAAA$AAAA",
         "$pbkdf2-sha256$i=0$AAAA$AAAA", "$pbkdf2-sha256$i=99999999999$AAAA$AAAA",
         "$pbkdf2-sha256$i=1000$!!!!$!!!!", "$pbkdf2-sha256$i=1000$AAAA$AAAA"]
  bad.each { |s| assert !PasswordHash.verify("correct horse battery", s) }
end

test "needs_rehash? notices a lower iteration count" do
  old = PasswordHash.create("correct horse battery")
  assert !PasswordHash.needs_rehash?(old)
  PasswordHash.iterations = 2000
  assert PasswordHash.needs_rehash?(old)
  assert PasswordHash.needs_rehash?("garbage")
  PasswordHash.iterations = 1000
end

test "the password policy rejects short, long and NUL passwords" do
  assert_equal "", PasswordHash.policy_error("long enough pw")
  assert PasswordHash.policy_error("short").bytesize > 0
  assert PasswordHash.policy_error("x" * 1025).bytesize > 0
  assert PasswordHash.policy_error("abc\0defghij").bytesize > 0
end

test "creating a hash for a policy-violating password raises" do
  raised = false
  begin
    PasswordHash.create("short")
  rescue ArgumentError
    raised = true
  end
  assert raised
end

test "an oversized password is simply not a match" do
  stored = PasswordHash.create("correct horse battery")
  assert !PasswordHash.verify("x" * 5000, stored)
end

test "dummy_verify is always false" do
  assert !PasswordHash.dummy_verify("whatever it is")
end

KaisatsuTest.run!
