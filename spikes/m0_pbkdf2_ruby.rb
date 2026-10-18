# M0: PBKDF2-HMAC-SHA256 in Ruby over Digest::SHA256.digest. Usage: m0_pbkdf2_ruby ITERATIONS
require "digest"

def hmac(ikey, okey, data)
  Digest::SHA256.digest(okey + Digest::SHA256.digest(ikey + data))
end

def pbkdf2_block1(password, salt, iterations)
  key = password.bytesize > 64 ? Digest::SHA256.digest(password) : password
  ipad = ("6" * 64).b
  opad = ("\\" * 64).b
  i = 0
  while i < key.bytesize
    b = key.getbyte(i)
    ipad.setbyte(i, b ^ 0x36)
    opad.setbyte(i, b ^ 0x5c)
    i += 1
  end
  u = hmac(ipad, opad, salt.b + "\0\0\0\1".b)
  t = u.dup
  n = 1
  while n < iterations
    u = hmac(ipad, opad, u)
    j = 0
    while j < 32
      t.setbyte(j, t.getbyte(j) ^ u.getbyte(j))
      j += 1
    end
    n += 1
  end
  t
end

iters = ARGV[0].to_i
t0 = Time.now
out = pbkdf2_block1("password", "salt", iters)
dt = Time.now - t0
puts out.unpack1("H*") rescue puts out.bytes.map { |b| "%02x" % b }.join
puts "iterations=#{iters} seconds=#{dt}"
