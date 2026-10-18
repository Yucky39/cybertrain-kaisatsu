# The files `kaisatsu install` writes, as (path, content) pairs. %{ts} in a path is
# replaced by a UTC timestamp (YYYYMMDDHHMM) so the migrations sort after the existing ones.
# Generated from a working demo application; keep them in step with it.
module Cybertrain
  module Kaisatsu
    module CLI
      module Templates
        FILES = [
          [
            "db/migrate/%{ts}00_create_users.rb",
            <<~'EOS_KAISATSU'
              class CreateUsers < Cybertrain::Migration::Base
                def change
                  create_table "users" do |t|
                    t.string "email", null: false
                    t.string "password_hash", null: false
                    t.timestamps
                  end
                  add_index "users", ["email"], unique: true
                end
              end
            EOS_KAISATSU
          ],
          [
            "db/migrate/%{ts}01_create_kaisatsu_tables.rb",
            <<~'EOS_KAISATSU'
              class CreateKaisatsuTables < Cybertrain::Migration::Base
                def change
                  create_table "kaisatsu_sessions" do |t|
                    t.string "digest", null: false
                    t.string "user_id", null: false
                    t.integer "created_at", null: false
                    t.integer "expires_at", null: false
                  end
                  add_index "kaisatsu_sessions", ["digest"], unique: true
                  add_index "kaisatsu_sessions", ["user_id"]

                  create_table "kaisatsu_tokens" do |t|
                    t.string "digest", null: false
                    t.string "user_id", null: false
                    t.string "purpose", null: false
                    t.integer "expires_at", null: false
                    t.integer "used_at"
                  end
                  add_index "kaisatsu_tokens", ["digest"], unique: true
                  add_index "kaisatsu_tokens", ["user_id"]

                  create_table "kaisatsu_attempts" do |t|
                    t.string "bucket", null: false
                    t.integer "window_start", null: false
                    t.integer "failures", null: false
                  end
                  add_index "kaisatsu_attempts", ["bucket"], unique: true
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/models/user.rb",
            <<~'EOS_KAISATSU'
              # Columns come from gen/models/user.rb (generated from db/schema.rb).
              class User
                validates :email, presence: true, length: { maximum: 254 }
                validates :password_hash, presence: true
              end
            EOS_KAISATSU
          ],
          [
            "app/models/accounts.rb",
            <<~'EOS_KAISATSU'
              # Where Kaisatsu finds accounts: the users table.
              class AccountDirectory < Cybertrain::Kaisatsu::UserDirectory
                def credentials_for(login)
                  user = User.find_by(email: login)
                  return Cybertrain::Kaisatsu::Credentials.missing if user.nil?
                  Cybertrain::Kaisatsu::Credentials.new(true, user.id.to_s, user.password_hash)
                end

                def email_for(user_id)
                  user = User.find_by(id: user_id.to_i)
                  user.nil? ? "" : user.email
                end

                def store_password_hash(user_id, password_hash)
                  user = User.find_by(id: user_id.to_i)
                  return nil if user.nil?
                  user.password_hash = password_hash
                  user.save
                  nil
                end
              end

              # Sends the mail on its own thread, so a slow mail server neither holds a
              # database connection nor shows (through response time) whether an account
              # exists. The thread is started from a method (spikes/NOTES.md rule 21).
              class BackgroundNotifier < Cybertrain::Kaisatsu::Notifier
                def initialize(inner)
                  @inner = inner
                end

                def send_password_reset(email, link)
                  spawn_reset(@inner, email, link)
                end

                def send_password_changed(email)
                  spawn_changed(@inner, email)
                end

                private

                def spawn_reset(inner, email, link)
                  Thread.new { inner.send_password_reset(email, link) }
                  nil
                end

                def spawn_changed(inner, email)
                  Thread.new { inner.send_password_changed(email) }
                  nil
                end
              end

              # The application's Kaisatsu objects, built on first use with every
              # argument bound to a local first (spikes/NOTES.md rule 58).
              module Accounts
                @authenticator = nil
                @password_reset = nil

                def self.authenticator
                  built = @authenticator
                  if built.nil?
                    directory = AccountDirectory.new
                    built = Cybertrain::Kaisatsu::Authenticator.new(directory)
                    @authenticator = built
                  end
                  built
                end

                # The mail sender. ConsoleNotifier prints the link to the log: development
                # only. Replace it with a Notifier that sends mail (for example over
                # cybertrain-postal) before going live.
                def self.notifier
                  Cybertrain::Kaisatsu::ConsoleNotifier.new
                end

                # Where reset links point. Set KAISATSU_BASE_URL in production
                # (https://example.com, no trailing slash); it is never taken from the
                # request, whose Host header a client controls.
                def self.base_url
                  configured = ENV["KAISATSU_BASE_URL"]
                  configured.nil? || configured.empty? ? "http://127.0.0.1:3000" : configured
                end

                def self.password_reset
                  built = @password_reset
                  if built.nil?
                    auth = authenticator
                    directory = AccountDirectory.new
                    inner = notifier
                    mailer = BackgroundNotifier.new(inner)
                    built = Cybertrain::Kaisatsu::PasswordReset.new(auth, directory, mailer, base_url)
                    @password_reset = built
                  end
                  built
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/controllers/sessions_controller.rb",
            <<~'EOS_KAISATSU'
              class SessionsController < ApplicationController
                # GET /login
                def new_action
                end

                # POST /login
                def create
                  result = login_result
                  if result.ok?
                    Cybertrain::Kaisatsu::Gate.sign_in(ctx, result.session_id, result.user_id)
                    flash[:notice] = "Signed in."
                    redirect_to "/", status: :see_other
                  elsif result.status == "throttled"
                    flash.now[:alert] = "Too many attempts. Try again later."
                    render :new_action, status: 429
                  else
                    flash.now[:alert] = "Invalid email or password."
                    render :new_action, status: :unprocessable_entity
                  end
                end

                # DELETE /logout
                def destroy
                  sign_out_now
                  flash[:notice] = "Signed out."
                  redirect_to "/login", status: :see_other
                end

                private

                def login_result
                  email = params[:email].to_s
                  password = params[:password].to_s
                  ip = request.remote_addr
                  now = Time.now.to_i
                  # Everything the block needs is a local first: inside a DB.with block
                  # `self` is not the controller under Spinel, so request/ctx/params would not resolve.
                  DB.with do |conn|
                    Accounts.authenticator.login(conn, email, password, ip, now)
                  end
                end

                def sign_out_now
                  context = ctx
                  DB.with { |conn| Cybertrain::Kaisatsu::Gate.sign_out(context, conn) }
                  nil
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/controllers/registrations_controller.rb",
            <<~'EOS_KAISATSU'
              class RegistrationsController < ApplicationController
                # GET /signup
                def new_action
                end

                # POST /signup
                def create
                  email = params[:email].to_s.strip.downcase
                  password = params[:password].to_s
                  problem = signup_problem(email, password)
                  unless problem.empty?
                    flash.now[:alert] = problem
                    return render(:new_action, status: :unprocessable_entity)
                  end
                  user = User.new(email: email, password_hash: Cybertrain::Kaisatsu::PasswordHash.create(password))
                  user.save
                  flash[:notice] = "Account created. Please sign in."
                  redirect_to "/login", status: :see_other
                end

                private

                def signup_problem(email, password)
                  return "Email can't be blank" if email.empty?
                  return "Email is not valid" unless email.include?("@") && email.length <= 254
                  policy = Cybertrain::Kaisatsu::PasswordHash.policy_error(password)
                  return "Password: " + policy unless policy.empty?
                  return "Email is already taken" unless User.where(email: email).first.nil?
                  ""
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/views/sessions/new_action.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Sign in</h1>
              <%= form_with(url: "/login") do |f| %>
                <div class="field">
                  <%= f.label :email %>
                  <%= f.email_field :email, autocomplete: "username" %>
                </div>
                <div class="field">
                  <%= f.label :password %>
                  <%= f.password_field :password, autocomplete: "current-password" %>
                </div>
                <div class="actions">
                  <%= f.submit "Sign in" %>
                </div>
              <% end %>
              <p><a href="/signup">Create an account</a> · <a href="/password/forgot">Forgot your password?</a></p>
            EOS_KAISATSU
          ],
          [
            "app/views/registrations/new_action.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Create an account</h1>
              <%= form_with(url: "/signup") do |f| %>
                <div class="field">
                  <%= f.label :email %>
                  <%= f.email_field :email, autocomplete: "username" %>
                </div>
                <div class="field">
                  <%= f.label :password %>
                  <%= f.password_field :password, autocomplete: "new-password" %>
                </div>
                <div class="actions">
                  <%= f.submit "Create account" %>
                </div>
              <% end %>
              <p><a href="/login">Sign in</a></p>
            EOS_KAISATSU
          ],
          [
            "app/controllers/password_resets_controller.rb",
            <<~'EOS_KAISATSU'
              class PasswordResetsController < ApplicationController
                # GET /password/forgot
                def new_action
                end

                # POST /password/forgot
                # The answer is the same whether or not the address has an account.
                def create
                  send_reset_link(params[:email].to_s)
                  flash[:notice] = "If that address has an account, we sent a link to reset the password."
                  redirect_to "/login", status: :see_other
                end

                # GET /password/reset/:token
                def edit
                  @token = params[:token].to_s
                  unless token_still_valid?(@token)
                    flash[:alert] = "That link is invalid or has expired."
                    return redirect_to("/password/forgot", status: :see_other)
                  end
                  # The token is in the address bar: keep it out of the Referer header.
                  response.set_header("Referrer-Policy", "no-referrer")
                end

                # POST /password/reset
                def update
                  @token = params[:token].to_s
                  outcome = finish_reset(@token, params[:password].to_s)
                  if outcome.done?
                    flash[:notice] = "Your password was changed. Please sign in."
                    redirect_to "/login", status: :see_other
                  elsif outcome.status == "weak_password"
                    flash.now[:alert] = "Password: " + outcome.message
                    response.set_header("Referrer-Policy", "no-referrer")
                    render :edit, status: :unprocessable_entity
                  else
                    flash[:alert] = "That link is invalid or has expired."
                    redirect_to "/password/forgot", status: :see_other
                  end
                end

                private

                # Everything a DB.with block needs is a local first: inside the block `self`
                # is not the controller under Spinel.
                def send_reset_link(email)
                  ip = request.remote_addr
                  now = Time.now.to_i
                  DB.with do |conn|
                    Accounts.password_reset.request_reset(conn, email, ip, now)
                  end
                  nil
                end

                def token_still_valid?(token)
                  now = Time.now.to_i
                  DB.with do |conn|
                    Accounts.password_reset.token_valid?(conn, token, now)
                  end
                end

                def finish_reset(token, password)
                  now = Time.now.to_i
                  DB.with do |conn|
                    Accounts.password_reset.complete_reset(conn, token, password, now)
                  end
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/views/password_resets/new_action.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Reset your password</h1>
              <p>Enter your email address. If it has an account, we will send a link.</p>
              <%= form_with(url: "/password/forgot") do |f| %>
                <div class="field">
                  <%= f.label :email %>
                  <%= f.email_field :email, autocomplete: "username" %>
                </div>
                <div class="actions">
                  <%= f.submit "Send the link" %>
                </div>
              <% end %>
              <p><a href="/login">Back to sign in</a></p>
            EOS_KAISATSU
          ],
          [
            "app/views/password_resets/edit.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Choose a new password</h1>
              <%= form_with(url: "/password/reset") do |f| %>
                <%= f.hidden_field :token, value: @token %>
                <div class="field">
                  <%= f.label :password, "New password" %>
                  <%= f.password_field :password, autocomplete: "new-password" %>
                </div>
                <div class="actions">
                  <%= f.submit "Change password" %>
                </div>
              <% end %>
            EOS_KAISATSU
          ]
        ].freeze

        APPLICATION_CONTROLLER_BEFORE_ACTION = <<~'EOS_KAISATSU'.freeze
          # Kaisatsu: check the session id against the database on every request.
          before_action { |c| Cybertrain::Kaisatsu::Gate.resolve(c.ctx) }
        EOS_KAISATSU

        APPLICATION_CONTROLLER_HELPERS = <<~'EOS_KAISATSU'.freeze
          def signed_in?
            Cybertrain::Kaisatsu::Gate.signed_in?(ctx)
          end

          def current_user_id
            Cybertrain::Kaisatsu::Gate.user_id(ctx)
          end

          # Use as: before_action :require_login
          def require_login
            return if signed_in?
            flash[:alert] = "Please sign in."
            redirect_to "/login", status: :see_other
          end
        EOS_KAISATSU

        ROUTES = <<~'EOS_KAISATSU'.freeze
          get "/login", to: "sessions#new_action", as: "login"
          post "/login", to: "sessions#create", as: "create_session"
          delete "/logout", to: "sessions#destroy", as: "logout"
          get "/signup", to: "registrations#new_action", as: "signup"
          post "/signup", to: "registrations#create", as: "create_registration"
          get "/password/forgot", to: "password_resets#new_action", as: "forgot_password"
          post "/password/forgot", to: "password_resets#create", as: "create_forgot_password"
          get "/password/reset/:token", to: "password_resets#edit", as: "reset_password"
          post "/password/reset", to: "password_resets#update", as: "update_password"
        EOS_KAISATSU

        REQUIRE_LINE = %(require "cybertrain/kaisatsu/full"\n).freeze
      end
    end
  end
end
