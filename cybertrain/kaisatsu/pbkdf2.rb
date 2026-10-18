require "digest"

module Cybertrain
  module Kaisatsu
    # PBKDF2-HMAC-SHA256 (RFC 8018) over Digest::SHA256.digest, one 32-byte
    # block (dkLen = 32). The HMAC pads are built once per call. Measured
    # under Spinel 2026.09.12: 600,000 iterations take about 0.5 s
    # (docs/m0-findings.md). No bcrypt/argon2 exists in Spinel's stdlib.
    module Pbkdf2
      BLOCK_SIZE = 64
      DIGEST_SIZE = 32

      def self.derive(password, salt, iterations)
        key = password.bytesize > BLOCK_SIZE ? Digest::SHA256.digest(password) : password
        ipad = ("6" * BLOCK_SIZE).b
        opad = ("\\" * BLOCK_SIZE).b
        i = 0
        while i < key.bytesize
          b = key.getbyte(i)
          ipad.setbyte(i, b ^ 0x36)
          opad.setbyte(i, b ^ 0x5c)
          i += 1
        end

        u = Pbkdf2.mac(ipad, opad, salt.b + "\0\0\0\1".b)
        t = u.dup
        n = 1
        while n < iterations
          u = Pbkdf2.mac(ipad, opad, u)
          j = 0
          while j < DIGEST_SIZE
            t.setbyte(j, t.getbyte(j) ^ u.getbyte(j))
            j += 1
          end
          n += 1
        end
        t
      end

      def self.mac(ipad, opad, data)
        Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + data))
      end
    end
  end
end
