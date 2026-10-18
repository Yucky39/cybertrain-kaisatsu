require "digest"
require "cybertrain/kaisatsu/secure"

module Cybertrain
  module Kaisatsu
    # A one-time secret handed to a user (password reset, e-mail
    # confirmation, API access). Only its SHA-256 digest is stored, so a
    # database leak does not leak usable tokens. The value is 256 bits of
    # randomness, so a plain (unsalted, fast) hash is enough.
    class Token
      BYTES = 32

      attr_reader :raw, :digest, :expires_at

      def initialize(raw, digest, expires_at)
        @raw = raw
        @digest = digest
        @expires_at = expires_at
      end

      # now is epoch seconds (the caller owns the clock); ttl in seconds.
      def self.issue(now, ttl)
        raw = Secure.hex(Secure.random_bytes(BYTES))
        digest = Token.digest_of(raw)
        Token.new(raw, digest, now + ttl)
      end

      def self.digest_of(raw)
        Secure.hex(Digest::SHA256.digest(raw))
      end

      # Constant-time check of a presented token against the stored digest.
      def self.matches?(raw, stored_digest)
        Secure.equal?(digest_of(raw), stored_digest)
      end

      def self.expired?(expires_at, now)
        now >= expires_at
      end
    end
  end
end
