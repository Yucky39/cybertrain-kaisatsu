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
| `db/migrate/…_add_email_verified_at_to_users.rb` | `users.email_verified_at`(確認した時刻。NULL は未確認) |
| `db/migrate/…_add_pending_email_to_users.rb` | `users.pending_email`(変更を依頼した新しいアドレス。確認されるまでの控え) |
| `app/models/user.rb` | `User`(列は `db/schema.rb` から生成される) |
| `app/models/accounts.rb` | `AccountDirectory`(`users` 表を改札に結ぶ)と `Accounts.authenticator` |
| `app/controllers/sessions_controller.rb` | ログイン(`/login`)とログアウト(`DELETE /logout`) |
| `app/controllers/registrations_controller.rb` | 新規登録(`/signup`) |
| `app/controllers/password_resets_controller.rb` | パスワード再設定(`/password/forgot`、`/password/reset/:token`) |
| `app/controllers/email_verifications_controller.rb` | メールアドレスの確認(`/email/resend`、`/email/verify/:token`) |
| `app/controllers/email_changes_controller.rb` | メールアドレスの変更(`/account/email`、`/email/change/:token`) |
| `app/views/sessions/`、`app/views/registrations/`、`app/views/password_resets/`、`app/views/email_verifications/`、`app/views/email_changes/` | フォーム |

既存のファイルへは、次の小さな追記だけを行う(2 回目以降は何もしない)。

- `spin.toml`: `cybertrain-kaisatsu` の依存を追加。
- `config/app.rb`: 先頭に `require "cybertrain/kaisatsu/full"`。
- `app/controllers/application_controller.rb`: `before_action { |c| Cybertrain::Kaisatsu::Gate.resolve(c.ctx) }`(毎リクエスト、セッション ID を DB で確認する)と、`signed_in?` / `current_user_id` / `require_login`。
- `config/routes.rb`: 17 本のルート(足りない分だけを足す)。

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

メールの送り先は `app/models/mail_setup.rb` の `MailSetup.notifier` で決める。何も指定せずに入れると `ConsoleNotifier` で、リンクをログに印字するだけ(開発専用。**リンクは秘密なので、本番ではログに出さない**)。実際にメールを送るには、`--postal` を付けて入れる(次の節)。自前の送信クラスを使うなら、`Cybertrain::Kaisatsu::Notifier` を継承して `MailSetup.notifier` から返す。

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



## メールアドレスの確認

1. 新規登録の直後に、確認のリンク(`/email/verify/<64 文字>`、3 日間有効、1 回限り)を送る。登録そのものは、確認を待たずに完了する。
2. リンクを開くと「Confirm」ボタンだけが出る。**開いただけでは確認されない**(メールのスキャナやリンクのプレビューがリンクを取得するため)。ボタンを押すと(POST)、`users.email_verified_at` に時刻が入る。
3. 届かなかったときは、`/email/resend` からメールアドレスを入れて再送する。アカウントの有無や確認済みかどうかにかかわらず、同じ応答になる。要求は、アカウント単位 3 回/時間、IP 単位 10 回/時間まで。

**確認済みのアドレスにしか、パスワード再設定のリンクを送らない。** 他人のアドレスで登録した人に、そのアドレス宛の秘密のリンクを出させないため。未確認のままだと、パスワードを忘れても再設定できない(ログイン自体は、確認前でもできる)。

アプリ側の使い方:

```ruby
Accounts.email_verified?(current_user_id.to_i)   # 画面の案内や、機能の出し分けに
```

**すでに入れてあるアプリへの追加**: ファイルは上書きしない(`skip`)ので、新しい分だけが足される(移行、確認用のコントローラとビュー、ルート)。ただし、既存の `accounts.rb`(`email_verified?` / `mark_email_verified` / `Accounts.email_verification`)と `registrations_controller.rb`(登録直後の送信)は、`kaisatsu install` では更新されない。ファイルを一度退避して入れ直すか、`cybertrain/kaisatsu/cli/templates.rb` の内容を手で足す。**既存のユーザーは全員「未確認」になる**ので、再設定を使う前に、確認のリンクを要求してもらう必要がある。

## メールアドレスの変更

ログイン中のユーザーが、`/account/email` で新しいアドレスと**現在のパスワード**を入れる。

1. その時点では何も変わらない。**新しいアドレス**に確認のリンク(1 日有効、1 回限り)を送り、**古いアドレス**(確認済みのときだけ)に「変更が依頼された」と知らせる。
2. リンクを開くとボタンだけが出る(開いただけでは変わらない)。ボタンを押すと、アドレスが入れ替わり、新しいアドレスは確認済みになる。
3. 変更が済むと、そのアカウントの**すべてのセッションを終了**し、**未使用のリンク(再設定・確認)をすべて無効にする**(古いメールボックスに残ったリンクが使えないように)。古いアドレスに「変更された」と知らせる。新しいアドレスで入り直す。

守っていること:

- パスワードを間違えても何も起きない。間違いはログインと同じ制限(アカウントごとに 5 回/15 分)に数える。このフォームでパスワードを推測できない。
- 新しいアドレスが他のアカウントに使われていても、応答は成功のときと同じで、メールは送らない(誰がアカウントを持っているかを、ログイン中の人にも教えない)。確認のボタンを押す時点でも、重複を調べ直す(`users.email` の一意インデックスが最後の砦)。
- 変更の依頼は、ユーザーごとに 3 回/時間まで。新しい依頼を出すと、古いリンクは無効になる。

## メールを送る(`--postal`)

```sh
kaisatsu install --postal            # cybertrain-postal を Git から取る
kaisatsu install --postal-path DIR   # ローカルのチェックアウトを使う
```

Web 側は、メールをスプール(`storage/mail_spool/`、1 通 1 ファイル)に書くだけで、SMTP には接続しない。送るのは別プログラム `bin/mail_worker.rb`(`cybertrain spin run mail_worker`)で、失敗した分は間隔を空けて再試行し、恒久的な失敗は `failed/` に移す。

**分けている理由**: SMTP の TLS には OpenSSL が必要だが、OpenSSL をリンクしたバイナリでは、CyberTrain の Web サーバーがすべてのリクエストで `undefined method 'getbyte' for an instance of String` になる(Spinel 2026.09.12 で確認。`config/app.rb` に `require "openssl"` を足すだけで再現する。Issue #2)。ワーカーは Web とは別のバイナリなので影響を受けない。

Web 側の設定:

| 環境変数 | 内容 |
| --- | --- |
| `KAISATSU_MAIL_FROM` | 送信元アドレス。空ならメールは送らず、ログに印字する(開発) |
| `KAISATSU_MAIL_FROM_NAME` | 表示名(任意) |
| `KAISATSU_MAIL_SPOOL` | スプールのディレクトリ(既定 `storage/mail_spool`。ワーカーにも同じ値を渡す) |
| `KAISATSU_BASE_URL` | リンクの土台(`https://example.com`、末尾のスラッシュなし) |

ワーカー側の設定(`bin/mail_worker.rb` の冒頭にも書いてある):

| 環境変数 | 内容 |
| --- | --- |
| `KAISATSU_SMTP_HOST` / `KAISATSU_SMTP_PORT` | SMTP サーバー(ポートの既定は 587) |
| `KAISATSU_SMTP_TLS` | 未設定: STARTTLS を必須にし、失敗しても平文には落とさない / `implicit`: 最初から TLS(465) / `optional`: STARTTLS があれば使い、なければ平文(同じマシン上の中継・開発用) |
| `KAISATSU_SMTP_USER` / `KAISATSU_SMTP_PASSWORD` | 認証。パスワードは TLS か、ループバック宛にしか送らない |
| `KAISATSU_HELO` | EHLO で名乗る名前 |

macOS の Homebrew では、ワーカーのビルドに `export LIBRARY_PATH=$(brew --prefix openssl@3)/lib CPATH=$(brew --prefix openssl@3)/include` が要る。

運用:

- **web とワーカーは同じユーザーで動かす。** スプールのディレクトリは 0700、メールのファイルは 0600 で作られるので、別のユーザーはどちらも読み書きできない。別ユーザーにするなら、ディレクトリを自分で作って権限を決める。
- メールには有効期限がある(再設定 1 時間、メール確認 3 日、アドレス変更リンクとセキュリティ通知 1 日。リンクの期限と同じ)。期限を過ぎたメールは送らず `failed/` に移す。
- 配送は少なくとも 1 回で、同じメールが重複して届くことがある。生成されるメールはどれも、重複しても害のない内容(リンクと通知)にしてある。
- `failed/` には再設定リンクのような秘密が残りうるので、ワーカーが 1 日 1 回、7 日より古いものを消す。`failed/` の件数が増え続けるなら、SMTP の設定か送信先を疑う。

注意:

- `cybertrain-postal` のリポジトリが非公開だと、Git からの取得(`--postal`)は認証なしでは失敗する。公開するか、`--postal-path` を使う。
- メールの宛先・本文・リンクはログに出さない。ただし、CyberTrain のリクエストログには、リンクを開いたときの URL(`/password/reset/<トークン>`)が残る。トークンは 1 回限りで 1 時間で切れ、DB にはダイジェストしか保存しないので、使用後や期限後のログは無害だが、ログの取り扱いには注意する。
