# M0: does the bundled openssl package offer PKCS5/KDF? Usage: m0_pbkdf2_openssl ITERATIONS
require "openssl"
iters = ARGV[0].to_i
t0 = Time.now
out = OpenSSL::PKCS5.pbkdf2_hmac("password", "salt", iters, 32, "sha256")
dt = Time.now - t0
puts out.unpack1("H*")
puts "iterations=#{iters} seconds=#{dt}"
