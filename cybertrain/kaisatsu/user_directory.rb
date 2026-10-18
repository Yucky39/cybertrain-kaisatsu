module Cybertrain
  module Kaisatsu
    # What Kaisatsu knows about an account while signing in.
    class Credentials
      attr_reader :found, :user_id, :password_hash

      def initialize(found, user_id, password_hash)
        @found = found
        @user_id = user_id
        @password_hash = password_hash
      end

      def self.missing
        Credentials.new(false, "", "")
      end
    end

    # The application's side of the bargain: where accounts live. Subclass it
    # in the app (the generator emits one over the users table). The base
    # declares the hooks so Spinel can resolve the calls (NOTES rule 3).
    class UserDirectory
      # Credentials for a login name (e-mail), Credentials.missing when none.
      def credentials_for(login)
        Credentials.missing
      end

      # Stores a replacement password hash (rehash on sign-in, reset).
      def store_password_hash(user_id, password_hash)
        nil
      end
    end
  end
end
