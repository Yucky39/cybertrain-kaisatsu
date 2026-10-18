require_relative "support/harness"
require "cybertrain/kaisatsu"

include Cybertrain::Kaisatsu

def hexed(iterations)
  Secure.hex(Pbkdf2.derive("password", "salt", iterations))
end

# Known answers for PBKDF2-HMAC-SHA256, P="password", S="salt", dkLen=32.
test "one iteration matches the known answer" do
  assert_equal "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", hexed(1)
end

test "two iterations match the known answer" do
  assert_equal "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", hexed(2)
end

test "4096 iterations match the known answer" do
  assert_equal "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", hexed(4096)
end

test "a password longer than the block size is hashed down first" do
  a = Secure.hex(Pbkdf2.derive("p" * 100, "salt", 2))
  b = Secure.hex(Pbkdf2.derive("p" * 100, "salt", 2))
  assert_equal a, b
  assert_equal 64, a.bytesize
end

KaisatsuTest.run!
