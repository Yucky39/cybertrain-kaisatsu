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
            "db/migrate/%{ts}02_add_email_verified_at_to_users.rb",
            <<~'EOS_KAISATSU'
              class AddEmailVerifiedAtToUsers < Cybertrain::Migration::Base
                def change
                  add_column "users", "email_verified_at", :integer
                end
              end
            EOS_KAISATSU
          ],
          [
            "db/migrate/%{ts}03_add_pending_email_to_users.rb",
            <<~'EOS_KAISATSU'
              class AddPendingEmailToUsers < Cybertrain::Migration::Base
                def change
                  add_column "users", "pending_email", :string
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

                def email_verified?(user_id)
                  user = User.find_by(id: user_id.to_i)
                  !user.nil? && !user.email_verified_at.nil?
                end

                def mark_email_verified(user_id)
                  user = User.find_by(id: user_id.to_i)
                  return nil if user.nil?
                  user.email_verified_at = Time.now.to_i
                  user.save
                  nil
                end

                def email_taken?(email, except_user_id)
                  other = User.where(email: email).first
                  !other.nil? && other.id.to_s != except_user_id
                end

                def begin_email_change(user_id, new_email)
                  user = User.find_by(id: user_id.to_i)
                  return nil if user.nil?
                  user.pending_email = new_email
                  user.save
                  nil
                end

                def pending_email(user_id)
                  user = User.find_by(id: user_id.to_i)
                  user.nil? ? "" : user.pending_email.to_s
                end

                # The unique index on users.email is the last word: if the address was
                # taken in the meantime, the save fails and nothing changes.
                def apply_email_change(user_id)
                  user = User.find_by(id: user_id.to_i)
                  return false if user.nil?
                  pending = user.pending_email.to_s
                  return false if pending.empty? || email_taken?(pending, user_id)
                  user.email = pending
                  user.pending_email = ""
                  user.email_verified_at = Time.now.to_i
                  user.save
                rescue Cybertrain::DB::Error
                  false
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

                def send_email_verification(email, link)
                  spawn_verification(@inner, email, link)
                end

                def send_email_change_link(new_email, link)
                  spawn_change_link(@inner, new_email, link)
                end

                def send_email_change_requested(old_email, new_email)
                  spawn_change_requested(@inner, old_email, new_email)
                end

                def send_email_changed(old_email, new_email)
                  spawn_changed_notice(@inner, old_email, new_email)
                end

                def send_email_change_undo(old_email, new_email, link)
                  spawn_change_undo(@inner, old_email, new_email, link)
                end

                def send_signup_existing(email, link)
                  spawn_signup_existing(@inner, email, link)
                end

                def send_password_changed(email)
                  spawn_changed(@inner, email)
                end

                private

                def spawn_change_link(inner, new_email, link)
                  Thread.new { inner.send_email_change_link(new_email, link) }
                  nil
                end

                def spawn_change_requested(inner, old_email, new_email)
                  Thread.new { inner.send_email_change_requested(old_email, new_email) }
                  nil
                end

                def spawn_change_undo(inner, old_email, new_email, link)
                  Thread.new { inner.send_email_change_undo(old_email, new_email, link) }
                  nil
                end

                def spawn_signup_existing(inner, email, link)
                  Thread.new { inner.send_signup_existing(email, link) }
                  nil
                end

                def spawn_changed_notice(inner, old_email, new_email)
                  Thread.new { inner.send_email_changed(old_email, new_email) }
                  nil
                end

                def spawn_verification(inner, email, link)
                  Thread.new { inner.send_email_verification(email, link) }
                  nil
                end

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
                @email_verification = nil
                @email_change = nil

                def self.authenticator
                  built = @authenticator
                  if built.nil?
                    directory = AccountDirectory.new
                    built = Cybertrain::Kaisatsu::Authenticator.new(directory)
                    @authenticator = built
                  end
                  built
                end

                # The mail sender, chosen in app/models/mail_setup.rb.
                def self.notifier
                  MailSetup.notifier
                end

                # Where reset links point. Set KAISATSU_BASE_URL in production
                # (https://example.com, no trailing slash); it is never taken from the
                # request, whose Host header a client controls.
                def self.base_url
                  configured = ENV["KAISATSU_BASE_URL"]
                  configured.nil? || configured.empty? ? "http://127.0.0.1:3000" : configured
                end

                # Whether the account's address was confirmed (for a banner, or to
                # hold back a feature until it is).
                def self.email_verified?(user_id)
                  AccountDirectory.new.email_verified?(user_id)
                end

                def self.email_change
                  built = @email_change
                  if built.nil?
                    directory = AccountDirectory.new
                    inner = notifier
                    mailer = BackgroundNotifier.new(inner)
                    built = Cybertrain::Kaisatsu::EmailChange.new(directory, mailer, base_url)
                    @email_change = built
                  end
                  built
                end

                def self.email_verification
                  built = @email_verification
                  if built.nil?
                    directory = AccountDirectory.new
                    inner = notifier
                    mailer = BackgroundNotifier.new(inner)
                    built = Cybertrain::Kaisatsu::EmailVerification.new(directory, mailer, base_url)
                    @email_verification = built
                  end
                  built
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
                  ip = request.client_ip
                  now = Time.now.to_i
                  # Everything the block needs is a local first: inside a Cybertrain::DB.with block
                  # `self` is not the controller under Spinel, so request/ctx/params would not resolve.
                  Cybertrain::DB.with do |conn|
                    Accounts.authenticator.login(conn, email, password, ip, now)
                  end
                end

                def sign_out_now
                  context = ctx
                  Cybertrain::DB.with { |conn| Cybertrain::Kaisatsu::Gate.sign_out(context, conn) }
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
                  unless signup_allowed?(request.client_ip, Time.now.to_i)
                    flash.now[:alert] = "Too many sign-up attempts. Please try again later."
                    return render(:new_action, status: :too_many_requests)
                  end
                  problem = signup_problem(email, password)
                  unless problem.empty?
                    flash.now[:alert] = problem
                    return render(:new_action, status: :unprocessable_entity)
                  end
                  # The hash is made either way, so an address that already has an account
                  # costs the same time; and the answer below is the same either way.
                  hash = Cybertrain::Kaisatsu::PasswordHash.create(password)
                  if User.where(email: email).first.nil?
                    user = User.new(email: email, password_hash: hash)
                    unless user.save
                      flash.now[:alert] = "The account could not be created"
                      return render(:new_action, status: :unprocessable_entity)
                    end
                    send_confirmation(email)
                  else
                    tell_owner(email)
                  end
                  flash[:notice] = "Account created. We sent a link to confirm your email address. Please sign in."
                  redirect_to "/login", status: :see_other
                end

                private

                # Every try counts, not only the failed ones: ten per address in 15 minutes.
                def signup_allowed?(ip, now)
                  return true if ip.empty?
                  Cybertrain::DB.with do |conn|
                    Cybertrain::Kaisatsu::Throttle.hit(conn, "signup:" + ip, now, 10, 900)
                  end
                end

                # The address already has an account: the owner is told by mail, the person
                # at the form is not.
                def tell_owner(email)
                  ip = request.client_ip
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_verification.signup_again(conn, email, ip, now)
                  end
                  nil
                end

                # A Cybertrain::DB.with block cannot see the controller's request: bind first.
                def send_confirmation(email)
                  ip = request.client_ip
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_verification.request_verification(conn, email, ip, now)
                  end
                  nil
                end

                def signup_problem(email, password)
                  return "Email can't be blank" if email.empty?
                  return "Email is not valid" unless email.include?("@") && email.length <= 254
                  policy = Cybertrain::Kaisatsu::PasswordHash.policy_error(password)
                  return "Password: " + policy unless policy.empty?
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
              <p><a href="/signup">Create an account</a> · <a href="/password/forgot">Forgot your password?</a> · <a href="/email/resend">Confirm your email</a></p>
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

                # Everything a Cybertrain::DB.with block needs is a local first: inside the block `self`
                # is not the controller under Spinel.
                def send_reset_link(email)
                  ip = request.client_ip
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.password_reset.request_reset(conn, email, ip, now)
                  end
                  nil
                end

                def token_still_valid?(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.password_reset.token_valid?(conn, token, now)
                  end
                end

                def finish_reset(token, password)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
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
          ],
          [
            "app/controllers/email_verifications_controller.rb",
            <<~'EOS_KAISATSU'
              class EmailVerificationsController < ApplicationController
                # GET /email/resend
                def new_action
                end

                # POST /email/resend
                # The answer is the same whether or not the address has an account, or is confirmed.
                def create
                  send_link(params[:email].to_s)
                  flash[:notice] = "If that address needs confirming, we sent a link."
                  redirect_to "/login", status: :see_other
                end

                # GET /email/verify/:token
                # Opening the link only shows a button: mail scanners and link previews fetch
                # links, and must not confirm an address by doing so.
                def edit
                  @token = params[:token].to_s
                  unless token_still_valid?(@token)
                    flash[:alert] = "That link is invalid or has expired."
                    return redirect_to("/email/resend", status: :see_other)
                  end
                  response.set_header("Referrer-Policy", "no-referrer")
                end

                # POST /email/verify
                def update
                  if confirm(params[:token].to_s).done?
                    flash[:notice] = "Your email address is confirmed."
                    redirect_to "/login", status: :see_other
                  else
                    flash[:alert] = "That link is invalid or has expired."
                    redirect_to "/email/resend", status: :see_other
                  end
                end

                private

                # Everything a Cybertrain::DB.with block needs is a local first: inside the block `self`
                # is not the controller under Spinel.
                def send_link(email)
                  ip = request.client_ip
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_verification.request_verification(conn, email, ip, now)
                  end
                  nil
                end

                def token_still_valid?(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_verification.token_valid?(conn, token, now)
                  end
                end

                def confirm(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_verification.complete_verification(conn, token, now)
                  end
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/views/email_verifications/new_action.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Confirm your email address</h1>
              <p>Enter your email address and we will send a new link, if it needs confirming.</p>
              <%= form_with(url: "/email/resend") do |f| %>
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
            "app/views/email_verifications/edit.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Confirm your email address</h1>
              <p>Press the button to confirm that this is your email address.</p>
              <%= form_with(url: "/email/verify") do |f| %>
                <%= f.hidden_field :token, value: @token %>
                <div class="actions">
                  <%= f.submit "Confirm" %>
                </div>
              <% end %>
            EOS_KAISATSU
          ],
          [
            "app/controllers/email_changes_controller.rb",
            <<~'EOS_KAISATSU'
              class EmailChangesController < ApplicationController
                before_action :require_login, only: [:new_action, :create]

                # GET /account/email
                def new_action
                end

                # POST /account/email
                # Nothing changes yet: a link goes to the new address. The answer does not say
                # whether the address is already in use.
                def create
                  outcome = ask_for_change(current_user_id, params[:email].to_s, params[:password].to_s)
                  if outcome.accepted?
                    flash[:notice] = "If that address can be used, we sent a link to it. The change takes effect when you confirm."
                    redirect_to "/", status: :see_other
                  elsif outcome.status == "throttled"
                    flash.now[:alert] = "Too many attempts. Try again later."
                    render :new_action, status: 429
                  elsif outcome.status == "wrong_password"
                    flash.now[:alert] = "The password is not correct."
                    render :new_action, status: :unprocessable_entity
                  else
                    flash.now[:alert] = "Enter a different, valid email address."
                    render :new_action, status: :unprocessable_entity
                  end
                end

                # GET /email/change/:token
                # Opening the link only shows a button.
                def edit
                  @token = params[:token].to_s
                  unless token_still_valid?(@token)
                    flash[:alert] = "That link is invalid or has expired."
                    return redirect_to("/login", status: :see_other)
                  end
                  response.set_header("Referrer-Policy", "no-referrer")
                end

                # POST /email/change
                def update
                  outcome = confirm(params[:token].to_s)
                  if outcome.done?
                    flash[:notice] = "Your email address was changed. Please sign in with the new address."
                  elsif outcome.status == "taken"
                    flash[:alert] = "That address is now used by another account, so nothing was changed."
                  else
                    flash[:alert] = "That link is invalid or has expired."
                  end
                  redirect_to "/login", status: :see_other
                end

                # GET /email/revert/:token
                # The link in the notice to the OLD address. Opening it only shows a button.
                def revert_form
                  @token = params[:token].to_s
                  unless revert_still_valid?(@token)
                    flash[:alert] = "That link is invalid or has expired."
                    return redirect_to("/login", status: :see_other)
                  end
                  response.set_header("Referrer-Policy", "no-referrer")
                end

                # POST /email/revert
                def revert
                  outcome = undo(params[:token].to_s)
                  if outcome.done?
                    flash[:notice] = "Your old email address is back and every session was ended. " \
                                     "Someone may have had your password: reset it now."
                    redirect_to "/password/forgot", status: :see_other
                  else
                    flash[:alert] = outcome.status == "taken" ? "That address is now used by another account, so nothing was changed." : "That link is invalid or has expired."
                    redirect_to "/login", status: :see_other
                  end
                end

                private

                def revert_still_valid?(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_change.revert_valid?(conn, token, now)
                  end
                end

                def undo(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_change.revert_change(conn, token, now)
                  end
                end

                # Everything a Cybertrain::DB.with block needs is a local first: inside the block `self`
                # is not the controller under Spinel.
                def ask_for_change(user_id, new_email, password)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_change.request_change(conn, user_id, new_email, password, now)
                  end
                end

                def token_still_valid?(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_change.token_valid?(conn, token, now)
                  end
                end

                def confirm(token)
                  now = Time.now.to_i
                  Cybertrain::DB.with do |conn|
                    Accounts.email_change.complete_change(conn, token, now)
                  end
                end
              end
            EOS_KAISATSU
          ],
          [
            "app/views/email_changes/new_action.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Change your email address</h1>
              <p>We will send a link to the new address. The change takes effect when you confirm it there.</p>
              <%= form_with(url: "/account/email") do |f| %>
                <div class="field">
                  <%= f.label :email, "New email address" %>
                  <%= f.email_field :email, autocomplete: "email" %>
                </div>
                <div class="field">
                  <%= f.label :password, "Your current password" %>
                  <%= f.password_field :password, autocomplete: "current-password" %>
                </div>
                <div class="actions">
                  <%= f.submit "Send the link" %>
                </div>
              <% end %>
              <p><a href="/">Back</a></p>
            EOS_KAISATSU
          ],
          [
            "app/views/email_changes/revert_form.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Put your old email address back</h1>
              <p>The sign-in address of your account was changed. Press the button to undo it. Every signed-in session will end, and you will be asked to reset your password.</p>
              <%= form_with(url: "/email/revert") do |f| %>
                <%= f.hidden_field :token, value: @token %>
                <div class="actions">
                  <%= f.submit "Undo the change" %>
                </div>
              <% end %>
            EOS_KAISATSU
          ],
          [
            "app/views/email_changes/edit.html.erb",
            <<~'EOS_KAISATSU'
              <h1>Confirm your new email address</h1>
              <p>Press the button to use this address to sign in. Every signed-in session will end.</p>
              <%= form_with(url: "/email/change") do |f| %>
                <%= f.hidden_field :token, value: @token %>
                <div class="actions">
                  <%= f.submit "Confirm" %>
                </div>
              <% end %>
            EOS_KAISATSU
          ]
        ].freeze

        MAIL_SETUP_CONSOLE = <<~'EOS_KAISATSU'.freeze
          # Which Notifier sends Kaisatsu's mail. This one prints to the log, which is
          # for development only: a reset link is a secret. Reinstall with --postal to
          # send real mail over cybertrain-postal (delete this file first), or write
          # your own Cybertrain::Kaisatsu::Notifier here.
          module MailSetup
            def self.notifier
              Cybertrain::Kaisatsu::ConsoleNotifier.new
            end
          end
        EOS_KAISATSU

        MAIL_SETUP_POSTAL = <<~'EOS_KAISATSU'.freeze
          # Queues Kaisatsu's mail for cybertrain-postal. The web binary only writes the
          # message to a spool directory (a file per message); bin/mail_worker.rb, a
          # separate program, sends them. They are separate because a binary that links
          # OpenSSL (needed for SMTP over TLS) cannot also run the CyberTrain web server
          # at this Spinel release: every request fails with "undefined method 'getbyte'".
          #
          # Web settings (environment):
          #
          #   KAISATSU_MAIL_FROM       the sender address; when empty, mail is only printed
          #                            to the log (development)
          #   KAISATSU_MAIL_FROM_NAME  optional display name
          #   KAISATSU_MAIL_SPOOL      the spool directory (default storage/mail_spool);
          #                            the worker must be given the same one
          #
          # SMTP settings belong to the worker; see bin/mail_worker.rb. Nothing about the
          # recipient or the link is written to the log.
          #
          # Each message carries valid_for (seconds), the same as its link's lifetime: the
          # worker moves a mail that outlived it to failed/ instead of sending it. Delivery
          # is at least once, so a mail can arrive twice; every one here is harmless then.
          class PostalNotifier < Cybertrain::Kaisatsu::Notifier
            def initialize(delivery, from_address, from_name)
              @delivery = delivery
              @from_address = from_address
              @from_name = from_name
            end

            def send_password_reset(email, link)
              enqueue_text(email, "Reset your password",
                           "Someone asked to reset the password for this account.\n\n" \
                           "Open this link within one hour to choose a new password:\n\n" +
                           link + "\n\n" \
                           "If it was not you, ignore this mail: your password stays the same.\n", 3600)
            end

            def send_email_verification(email, link)
              enqueue_text(email, "Confirm your email address",
                           "Please confirm that this is your email address.\n\n" \
                           "Open this link and press the button within three days:\n\n" +
                           link + "\n\n" \
                           "If you did not create an account, ignore this mail.\n", 259200)
            end

            def send_email_change_link(new_email, link)
              enqueue_text(new_email, "Confirm your new email address",
                           "Someone asked to use this address to sign in to the account.\n\n" \
                           "Open this link and press the button within a day to confirm:\n\n" +
                           link + "\n\n" \
                           "If it was not you, ignore this mail: nothing changes until you confirm.\n", 86400)
            end

            def send_email_change_requested(old_email, new_email)
              enqueue_text(old_email, "A change of your sign-in address was requested",
                           "A change of the sign-in address of this account to another address " \
                           "was requested. It takes effect only when the new address is confirmed.\n\n" \
                           "If it was not you, change your password now.\n", 86400)
            end

            def send_email_changed(old_email, new_email)
              enqueue_text(old_email, "Your sign-in address was changed",
                           "The sign-in address of this account was changed to another address, " \
                           "and every signed-in session was ended.\n\n" \
                           "If it was not you, contact the administrator at once.\n", 86400)
            end

            def send_email_change_undo(old_email, new_email, link)
              enqueue_text(old_email, "Your sign-in address was changed",
                           "The sign-in address of this account was changed to another address, " \
                           "and every signed-in session was ended.\n\n" \
                           "If it was you, you need do nothing. If it was not, open this link within " \
                           "a week to put this address back, then reset your password:\n\n" +
                           link + "\n", 604800)
            end

            def send_signup_existing(email, link)
              enqueue_text(email, "Someone tried to sign up with your address",
                           "Someone tried to create an account with this address, which already has one.\n\n" \
                           "If it was you, just sign in. If you forgot your password, you can reset it:\n\n" +
                           link + "\n\n" \
                           "If it was not you, ignore this mail: nothing changed.\n", 259200)
            end

            def send_password_changed(email)
              enqueue_text(email, "Your password was changed",
                           "The password for this account was just changed, and every signed-in " \
                           "session was ended.\n\n" \
                           "If it was not you, reset the password now and check your account.\n", 86400)
            end

            private

            def enqueue_text(to, subject, body, valid_for)
              sender = Cybertrain::Postal::Address.build(@from_address, @from_name)
              message = Cybertrain::Postal::Message.new(sender)
              message.add_to(Cybertrain::Postal::Address.build(to, ""))
              message.subject = subject
              message.text_body = body
              message.valid_for = valid_for
              result = @delivery.deliver(message)
              puts "[kaisatsu] mail not queued (code #{result.code})" unless result.ok?
              nil
            rescue Cybertrain::Postal::InvalidMessage
              puts "[kaisatsu] mail not queued (the message was refused as invalid)"
              nil
            end
          end

          module MailSetup
            def self.notifier
              from = ENV["KAISATSU_MAIL_FROM"]
              if from.nil? || from.empty?
                # The console notifier prints every link to the log: fine while developing,
                # a leak in production.
                if ENV["CYBERTRAIN_ENV"] == "production"
                  raise "KAISATSU_MAIL_FROM is not set: refusing to print sign-in links to the log in production"
                end
                return Cybertrain::Kaisatsu::ConsoleNotifier.new
              end

              name = ENV["KAISATSU_MAIL_FROM_NAME"]
              dir = ENV["KAISATSU_MAIL_SPOOL"]
              spool = Cybertrain::Postal::Spool.new(dir.nil? || dir.empty? ? "storage/mail_spool" : dir)
              delivery = Cybertrain::Postal::QueueDelivery.new(spool)
              PostalNotifier.new(delivery, from, name.nil? ? "" : name)
            end
          end
        EOS_KAISATSU

        MAIL_WORKER = <<~'EOS_KAISATSU'.freeze
          # Sends the mail that the web application queued (see app/models/mail_setup.rb).
          # A separate program on purpose: it links OpenSSL for SMTP over TLS, which the
          # web binary cannot.
          #
          #   cybertrain spin run mail_worker            run until stopped
          #   cybertrain spin run mail_worker -- --once  one pass, then exit
          #
          # Settings (environment):
          #
          #   KAISATSU_SMTP_HOST       the SMTP server (required)
          #   KAISATSU_SMTP_PORT       587 by default
          #   KAISATSU_SMTP_TLS        unset: STARTTLS is required, and never downgraded to
          #                            plain text if it fails
          #                            "implicit": TLS from the start (port 465)
          #                            "optional": STARTTLS when offered, plain text otherwise;
          #                            for a relay on the same machine (a mail catcher in
          #                            development). The password is only ever sent over
          #                            TLS or to a loopback address.
          #   KAISATSU_SMTP_USER / KAISATSU_SMTP_PASSWORD
          #   KAISATSU_HELO            the name given in EHLO (default localhost)
          #   KAISATSU_MAIL_SPOOL      the spool directory (default storage/mail_spool)
          #
          # On macOS with Homebrew, build with
          #   export LIBRARY_PATH=$(brew --prefix openssl@3)/lib CPATH=$(brew --prefix openssl@3)/include
          require "cybertrain/postal"
          require "cybertrain/postal/smtp_factory"

          def setting(name, fallback)
            value = ENV[name]
            value.nil? || value.empty? ? fallback : value
          end

          host = setting("KAISATSU_SMTP_HOST", "")
          if host.empty?
            puts "mail_worker: KAISATSU_SMTP_HOST is not set"
            exit(1)
          end

          tls = setting("KAISATSU_SMTP_TLS", "")
          factory = Cybertrain::Postal::SmtpDeliveryFactory.new(
            host,
            setting("KAISATSU_SMTP_PORT", "587").to_i,
            tls == "implicit",
            setting("KAISATSU_HELO", "localhost")
          )
          factory.require_tls = false if tls == "optional"
          user = setting("KAISATSU_SMTP_USER", "")
          factory.credentials(user, setting("KAISATSU_SMTP_PASSWORD", "")) unless user.empty?

          spool = Cybertrain::Postal::Spool.new(setting("KAISATSU_MAIL_SPOOL", "storage/mail_spool"))
          policy = Cybertrain::Postal::RetryPolicy.new(8, 30.0, 3600.0)
          runner = Cybertrain::Postal::SpoolRunner.new(spool, factory, policy)
          once = ARGV.include?("--once")

          # failed/ can hold a reset link, so it is emptied after a week, once a day.
          day = 24 * 3600
          last_purge = 0

          running = true
          while running
            now = Time.now.to_i
            spool.recover_stale(now, 600)
            if now - last_purge >= day
              spool.purge_failed(now, 7 * day)
              last_purge = now
            end
            report = runner.run_once(now)
            if report.delivered + report.deferred + report.failed > 0
              puts "[mail_worker] delivered=#{report.delivered} deferred=#{report.deferred} failed=#{report.failed} refused=#{report.refused}"
              STDOUT.flush
            end
            if once
              running = false
            else
              sleep(5)
            end
          end
        EOS_KAISATSU

        # Only the core of postal: it does not pull in OpenSSL (see MAIL_SETUP_POSTAL).
        POSTAL_REQUIRES = <<~'EOS_KAISATSU'.freeze
          require "cybertrain/postal"
        EOS_KAISATSU

        APPLICATION_CONTROLLER_BEFORE_ACTION = <<~'EOS_KAISATSU'.freeze
          # Kaisatsu: check the session id against the database on every request.
          before_action :resolve_kaisatsu_session
        EOS_KAISATSU

        APPLICATION_CONTROLLER_HELPERS = <<~'EOS_KAISATSU'.freeze
          # Who is signed in is looked up once per request and kept here, not in the
          # cookie. A controller that does not inherit this one never runs it.
          def resolve_kaisatsu_session
            @kaisatsu_user_id = Cybertrain::Kaisatsu::Gate.resolve(ctx)
            nil
          end

          def signed_in?
            current_user_id.bytesize > 0
          end

          def current_user_id
            uid = @kaisatsu_user_id
            uid.nil? ? "" : uid
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
          get "/email/resend", to: "email_verifications#new_action", as: "resend_verification"
          post "/email/resend", to: "email_verifications#create", as: "create_resend_verification"
          get "/email/verify/:token", to: "email_verifications#edit", as: "verify_email"
          post "/email/verify", to: "email_verifications#update", as: "update_verify_email"
          get "/account/email", to: "email_changes#new_action", as: "change_email"
          post "/account/email", to: "email_changes#create", as: "create_change_email"
          get "/email/change/:token", to: "email_changes#edit", as: "confirm_email_change"
          post "/email/change", to: "email_changes#update", as: "update_email_change"
          get "/email/revert/:token", to: "email_changes#revert_form", as: "revert_email_change_form"
          post "/email/revert", to: "email_changes#revert", as: "revert_email_change"
        EOS_KAISATSU

        REQUIRE_LINE = %(require "cybertrain/kaisatsu/full"\n).freeze
      end
    end
  end
end
