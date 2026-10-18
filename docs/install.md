# アプリへの組み込み(`kaisatsu install`)

cybertrain のアプリのディレクトリで実行する。

```sh
ruby /path/to/cybertrain-kaisatsu/exe/kaisatsu install --path /path/to/cybertrain-kaisatsu
cybertrain db migrate
cybertrain server
```

`--path` を省略すると、`spin.toml` の依存は GitHub の `main` ブランチを指す(固定されないので、公開後はタグを `--ref` で指定する)。

## 作られるもの

| 場所 | 内容 |
| --- | --- |
| `db/migrate/…_create_users.rb` | `users`(`email` は一意、`password_hash`) |
| `db/migrate/…_create_kaisatsu_tables.rb` | `kaisatsu_sessions` / `kaisatsu_tokens` / `kaisatsu_attempts` |
| `app/models/user.rb` | `User`(列は `db/schema.rb` から生成される) |
| `app/models/accounts.rb` | `AccountDirectory`(`users` 表を改札に結ぶ)と `Accounts.authenticator` |
| `app/controllers/sessions_controller.rb` | ログイン(`/login`)とログアウト(`DELETE /logout`) |
| `app/controllers/registrations_controller.rb` | 新規登録(`/signup`) |
| `app/controllers/password_resets_controller.rb` | パスワード再設定(`/password/forgot`、`/password/reset/:token`) |
| `app/views/sessions/`、`app/views/registrations/`、`app/views/password_resets/` | フォーム |

既存のファイルへは、次の小さな追記だけを行う(2 回目以降は何もしない)。

- `spin.toml`: `cybertrain-kaisatsu` の依存を追加。
- `config/app.rb`: 先頭に `require "cybertrain/kaisatsu/full"`。
- `app/controllers/application_controller.rb`: `before_action { |c| Cybertrain::Kaisatsu::Gate.resolve(c.ctx) }`(毎リクエスト、セッション ID を DB で確認する)と、`signed_in?` / `current_user_id` / `require_login`。
- `config/routes.rb`: 9 本のルート(足りない分だけを足す)。

既存のファイルが想定の形でないときは、`MANUAL` と表示される。上の内容を手で足す。

## 使い方

```ruby
class PostsController < ApplicationController
  before_action :require_login   # 未ログインなら /login へ
  def index
    @owner = current_user_id     # ログイン中のユーザー ID(文字列)
  end
end
```

## 注意

- パスワードの確認に約 0.5 秒かかる(PBKDF2、60万回。Spinel での測定値)。`SPINEL_WORKERS` が 1 だと、その間は他のリクエストが止まる。2 以上にする。
- コントローラの中の `DB.with { |conn| … }` ブロックでは、`request` / `ctx` / `params` を直接呼べない(Spinel ではブロックの `self` がコントローラにならない)。必要な値は、ブロックの前にローカル変数へ入れる。
- ログインの失敗は、アカウントごとに 5 回/15 分、IP ごとに 20 回/15 分で止まる(HTTP 429)。IP は接続元のアドレス。逆プロキシの背後では、すべて同じ IP に見えるので、IP 単位の制限が共有される点に注意する。

## パスワード再設定

1. `/password/forgot` でメールアドレスを入れる。アカウントがあってもなくても、同じ画面(ログインへ戻り、「リンクを送った」と表示)になる。
2. アカウントがあれば、1 時間有効な 1 回限りのリンク(`/password/reset/<64 文字>`)を送る。再発行すると古いリンクは無効になる。
3. リンクを開くと、新しいパスワードのフォームが出る。トークンは URL にあるので、`Referrer-Policy: no-referrer` を付けて外部に漏らさない。
4. 弱いパスワード(8 文字未満など)はリンクを消費せずに拒否する。成功すると、そのユーザーの全セッションを終了し、ログイン画面へ戻す(自動ログインはしない)。

守っていること:

- 要求は、アカウント単位で 3 回/時間、IP 単位で 10 回/時間まで(超えても同じ応答。黙って送らない)。アカウントの有無にかかわらず数える。
- メールの送信は別スレッド(`BackgroundNotifier`)で行う。遅いメールサーバーがデータベース接続を占有せず、応答時間でアカウントの有無が分からない。
- リンクの URL は `KAISATSU_BASE_URL`(本番で必ず設定。末尾のスラッシュなし)から作る。リクエストの `Host` ヘッダーは使わない(クライアントが変えられるため)。

メールの送り先は `app/models/accounts.rb` の `Accounts.notifier` で決める。生成直後は `ConsoleNotifier` で、リンクをログに印字するだけ(開発専用。**リンクは秘密なので、本番ではログに出さない**)。本番では `Cybertrain::Kaisatsu::Notifier` を継承した送信クラス(例: cybertrain-postal 経由)に替える。

```ruby
class MailNotifier < Cybertrain::Kaisatsu::Notifier
  def send_password_reset(email, link)
    # メールを送る(本文にリンクを入れる)
    nil
  end

  def send_password_changed(email)
    # 「パスワードが変更されました」の通知を送る
    nil
  end
end
```

注意: メールアドレスの確認(`email_verified`)はまだない。未確認のアドレスにも再設定のリンクを送る。
