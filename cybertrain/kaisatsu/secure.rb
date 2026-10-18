require "securerandom"

module Cybertrain
  module Kaisatsu
    # Byte-level helpers. Kept here, not borrowed from the framework's Crypto,
    # so the pure parts of the library load without cybertrain.
    module Secure
      HEX_DIGITS = "0123456789abcdef"

      # Lowercase hex of raw bytes, filled with setbyte (spikes/NOTES.md rule 56).
      def self.hex(bytes)
        n = bytes.bytesize
        out = "0" * (n * 2)
        i = 0
        while i < n
          b = bytes.getbyte(i)
          out.setbyte(i * 2, HEX_DIGITS.getbyte((b >> 4) & 0xf))
          out.setbyte(i * 2 + 1, HEX_DIGITS.getbyte(b & 0xf))
          i += 1
        end
        out
      end

      # Constant-time comparison: every byte pair is examined whatever the
      # first mismatch, so timing does not reveal how much matched.
      def self.equal?(a, b)
        return false if a.bytesize != b.bytesize
        diff = 0
        i = 0
        n = a.bytesize
        while i < n
          diff |= (a.getbyte(i) ^ b.getbyte(i))
          i += 1
        end
        diff == 0
      end

      def self.random_bytes(count)
        SecureRandom.random_bytes(count)
      end
    end
  end
end
