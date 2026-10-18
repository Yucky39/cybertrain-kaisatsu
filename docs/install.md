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
| `app/views/sessions/`、`app/views/registrations/` | フォーム |

既存のファイルへは、次の小さな追記だけを行う(2 回目以降は何もしない)。

- `spin.toml`: `cybertrain-kaisatsu` の依存を追加。
- `config/app.rb`: 先頭に `require "cybertrain/kaisatsu/full"`。
- `app/controllers/application_controller.rb`: `before_action { |c| Cybertrain::Kaisatsu::Gate.resolve(c.ctx) }`(毎リクエスト、セッション ID を DB で確認する)と、`signed_in?` / `current_user_id` / `require_login`。
- `config/routes.rb`: 5 本のルート。

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
- メールによるパスワード再設定は、まだ組み込まれていない(`TokenStore` はある)。
