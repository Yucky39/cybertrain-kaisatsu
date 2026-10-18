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

                def store_password_hash(user_id, password_hash)
                  user = User.find_by(id: user_id.to_i)
                  return nil if user.nil?
                  user.password_hash = password_hash
                  user.save
                  nil
                end
              end

              # The one Authenticator of the application. Built on first use, with the
              # directory bound to a local first (spikes/NOTES.md rule 58).
              module Accounts
                @authenticator = nil

                def self.authenticator
                  built = @authenticator
                  if built.nil?
                    directory = AccountDirectory.new
                    built = Cybertrain::Kaisatsu::Authenticator.new(directory)
                    @authenticator = built
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
              <p><a href="/signup">Create an account</a></p>
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
        EOS_KAISATSU

        REQUIRE_LINE = %(require "cybertrain/kaisatsu/full"\n).freeze
      end
    end
  end
end
