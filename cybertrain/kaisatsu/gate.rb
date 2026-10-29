require "cybertrain/middleware"
require "cybertrain/db"
require "cybertrain/kaisatsu/server_sessions"

module Cybertrain
  module Kaisatsu
    # The turnstile (改札口). Put it right after SessionStore in the stack:
    # on every request it checks the session id in the cookie session against
    # the database. The cookie carries only that random id; who is signed in is
    # never copied into it, so ending a server session takes effect at once and
    # a request that skips the check sees nobody signed in. Controllers get the
    # user from Gate.resolve (the generated ApplicationController keeps it for
    # the request); Gate.user_id / Gate.signed_in? ask the database again.
    class Gate < Middleware
      SID_KEY = "_kaisatsu_sid"
      # Older versions copied the user id into the cookie under this key; it is
      # removed when found and never read.
      UID_KEY = "_kaisatsu_uid"

      def call(ctx)
        Gate.resolve(ctx)
        super
      end

      # The user id of the live session in the cookie, "" when nobody is signed
      # in. Removes the session id from the cookie when it is unknown, expired
      # or ended. One database lookup per call: a controller's before_action
      # calls it once (`@user_id = Cybertrain::Kaisatsu::Gate.resolve(ctx)`)
      # where the stack cannot be changed.
      def self.resolve(ctx)
        session = ctx.session
        return "" if session.nil?
        session.delete(UID_KEY)
        sid = session[SID_KEY]
        return "" if sid.nil? || sid.empty?
        uid = DB.with { |conn| ServerSessions.resolve_user(conn, sid, Time.now.to_i) }
        session.delete(SID_KEY) if uid.empty?
        uid
      end

      # "" when nobody is signed in.
      def self.user_id(ctx)
        resolve(ctx)
      end

      def self.signed_in?(ctx)
        user_id(ctx).bytesize > 0
      end

      # Starts a signed-in session: replaces the cookie session's contents
      # (a fresh CSRF token, no leftovers from before sign-in: fixation) and
      # stores the id Authenticator#login returned. user_id is not kept.
      def self.sign_in(ctx, session_id, user_id)
        session = ctx.session
        return nil if session.nil?
        session.clear
        session[SID_KEY] = session_id
        nil
      end

      # Ends the current server session and empties the cookie session.
      def self.sign_out(ctx, conn)
        session = ctx.session
        return nil if session.nil?
        sid = session[SID_KEY]
        ServerSessions.close_session(conn, sid) unless sid.nil? || sid.empty?
        session.clear
        nil
      end

      # Answers 302 to login_path unless someone is signed in. Returns true
      # when the request was turned away (stop processing then).
      def self.require_login(ctx, login_path)
        return false if signed_in?(ctx)
        ctx.response.redirect(login_path)
        true
      end
    end
  end
end
