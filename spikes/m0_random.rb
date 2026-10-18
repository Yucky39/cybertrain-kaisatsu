# M0: SecureRandom availability and shape.
require "securerandom"
a = SecureRandom.random_bytes(32)
b = SecureRandom.random_bytes(32)
puts a.bytesize
puts (a == b) ? "same" : "different"
puts SecureRandom.hex(16).bytesize
