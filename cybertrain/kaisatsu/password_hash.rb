require "base64"
require "cybertrain/kaisatsu/secure"
require "cybertrain/kaisatsu/pbkdf2"

module Cybertrain
  module Kaisatsu
    # Stored form: "$pbkdf2-sha256$i=<iterations>$<salt>$<hash>", salt and hash
    # in unpadded base64. The parameters travel with the hash, so raising the
    # iteration count later is detected by needs_rehash? and fixed on the next
    # successful login.
    module PasswordHash
      ALGORITHM = "pbkdf2-sha256"
      SALT_BYTES = 16
      DEFAULT_ITERATIONS = 600_000
      MAX_ITERATIONS = 10_000_000
      MAX_PASSWORD_BYTES = 1024
      MIN_PASSWORD_BYTES = 8

      # The iteration count new hashes use. A module-level instance variable
      # with accessors, not @@var (spikes/NOTES.md rule 18). Tests lower it.
      @iterations = DEFAULT_ITERATIONS

      def self.iterations
        @iterations
      end

      def self.iterations=(count)
        @iterations = count
      end

      # "" when the password is acceptable, else a short reason.
      def self.policy_error(password)
        return "password is too short" if password.bytesize < MIN_PASSWORD_BYTES
        return "password is too long" if password.bytesize > MAX_PASSWORD_BYTES
        return "password contains a NUL byte" if password.include?("\0")
        ""
      end

      def self.create(password)
        err = policy_error(password)
        raise ArgumentError, err if err.bytesize > 0
        salt = Secure.random_bytes(SALT_BYTES)
        count = @iterations
        digest = Pbkdf2.derive(password, salt, count)
        "$" + ALGORITHM + "$i=" + count.to_s + "$" + encode(salt) + "$" + encode(digest)
      end

      # True only for a well-formed stored hash that matches. Anything
      # malformed, or an oversized password, is simply false.
      def self.verify(password, stored)
        return false if password.bytesize > MAX_PASSWORD_BYTES
        parts = stored.split("$")
        return false unless parts.length == 5 && parts[0] == "" && parts[1] == ALGORITHM
        count = parse_iterations(parts[2])
        return false if count < 1
        salt = decode(parts[3])
        expected = decode(parts[4])
        return false if salt.bytesize == 0 || expected.bytesize != Pbkdf2::DIGEST_SIZE
        actual = Pbkdf2.derive(password, salt, count)
        Secure.equal?(actual, expected)
      end

      # True when the stored hash is unreadable or uses fewer iterations than
      # the current setting.
      def self.needs_rehash?(stored)
        parts = stored.split("$")
        return true unless parts.length == 5 && parts[1] == ALGORITHM
        parse_iterations(parts[2]) < @iterations
      end

      # Burns the same time as a real check, for a login with an unknown
      # account, so response time does not reveal whether the account exists.
      # Always false.
      def self.dummy_verify(password)
        Pbkdf2.derive(password, "kaisatsu-dummy-salt", @iterations)
        false
      end

      def self.parse_iterations(field)
        return 0 unless field.start_with?("i=")
        digits = field.byteslice(2, field.bytesize - 2)
        return 0 if digits.bytesize == 0 || digits.bytesize > 8
        n = 0
        i = 0
        while i < digits.bytesize
          b = digits.getbyte(i)
          return 0 if b < 48 || b > 57
          n = n * 10 + (b - 48)
          i += 1
        end
        n > MAX_ITERATIONS ? 0 : n
      end

      def self.encode(bytes)
        Base64.strict_encode64(bytes).delete("=")
      end

      # "" for input that is not valid base64.
      def self.decode(text)
        i = 0
        while i < text.bytesize
          b = text.getbyte(i)
          ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 43 || b == 47
          return "" unless ok
          i += 1
        end
        return "" if text.bytesize % 4 == 1
        padded = text + ("=" * ((4 - text.bytesize % 4) % 4))
        Base64.strict_decode64(padded)
      end
    end
  end
end
