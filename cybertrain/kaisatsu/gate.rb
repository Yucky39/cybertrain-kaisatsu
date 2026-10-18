require "cybertrain/middleware"
require "cybertrain/db"
require "cybertrain/kaisatsu/server_sessions"

module Cybertrain
  module Kaisatsu
    # The turnstile (改札口). Put it right after SessionStore in the stack:
    # on every request it checks the session id in the cookie session against
    # the database and publishes the signed-in user id, or removes both keys
    # when the id is unknown, expired or ended. Controllers read the user
    # through Gate.user_id / Gate.signed_in?; nothing else in the cookie is
    # trusted for identity, so ending a server session takes effect at once.
    class Gate < Middleware
      SID_KEY = "_kaisatsu_sid"
      UID_KEY = "_kaisatsu_uid"

      def call(ctx)
        Gate.resolve(ctx)
        super
      end

      # The work of the middleware, callable on its own: a controller's
      # before_action can run it where the stack cannot be changed
      # (`before_action { |c| Cybertrain::Kaisatsu::Gate.resolve(c.ctx) }`).
      def self.resolve(ctx)
        session = ctx.session
        return nil if session.nil?
        sid = session[SID_KEY]
        if sid.nil? || sid.empty?
          session.delete(UID_KEY)
        else
          uid = DB.with { |conn| ServerSessions.resolve_user(conn, sid, Time.now.to_i) }
          if uid.empty?
            session.delete(SID_KEY)
            session.delete(UID_KEY)
          else
            session[UID_KEY] = uid
          end
        end
        nil
      end

      # "" when nobody is signed in.
      def self.user_id(ctx)
        session = ctx.session
        return "" if session.nil?
        uid = session[UID_KEY]
        uid.nil? ? "" : uid
      end

      def self.signed_in?(ctx)
        user_id(ctx).bytesize > 0
      end

      # Starts a signed-in session: replaces the cookie session's contents
      # (a fresh CSRF token, no leftovers from before sign-in: fixation) and
      # stores the id Authenticator#login returned.
      def self.sign_in(ctx, session_id, user_id)
        session = ctx.session
        return nil if session.nil?
        session.clear
        session[SID_KEY] = session_id
        session[UID_KEY] = user_id
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
