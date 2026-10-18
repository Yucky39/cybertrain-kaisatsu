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

      # The e-mail address of an account ("" when unknown), for notices that
      # follow an action (a password was changed).
      def email_for(user_id)
        ""
      end

      # Whether the account's e-mail address has been confirmed. Mail that
      # carries a secret (a password reset link) goes only to confirmed addresses.
      def email_verified?(user_id)
        false
      end

      # Records that the address was confirmed (by a click on the mailed link).
      def mark_email_verified(user_id)
        nil
      end

      # Stores a replacement password hash (rehash on sign-in, reset).
      def store_password_hash(user_id, password_hash)
        nil
      end
    end
  end
end
