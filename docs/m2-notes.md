# M2 実装メモ(ローカル作業中)

## できたもの

- `Schema`(`kaisatsu_sessions` / `kaisatsu_tokens` / `kaisatsu_attempts`)。`Schema.install(conn)` は何度呼んでもよい。
- `ServerSessions`: サーバ側セッション。クッキーにはランダムな ID だけを載せ、DB にはそのダイジェストを保存する。個別の終了と「全端末ログアウト」ができる。
- `TokenStore`: パスワード再設定・メール確認用の 1 回限りのトークン。消費は単一の `UPDATE` で行い、同時リクエストの二重利用を防ぐ。同じ用途の新しいトークンを発行すると、古いものは無効になる。
- `Throttle`: 固定ウィンドウの失敗カウンタ(DB)。キーはダイジェストで保存する(メールアドレスや IP を平文で残さない)。
- `Authenticator#login`: 試行制限 → 認証 → 必要なら再ハッシュ → セッション作成。アカウントが無い場合も `dummy_verify` で同じ時間を使い、失敗の応答は 1 種類(`invalid`)。アカウント単位 5 回/15 分、IP 単位 20 回/15 分。
- `Gate`(ミドルウェア): `SessionStore` の直後に置く。毎リクエスト、クッキー内のセッション ID を DB で確認し、サインイン中のユーザー ID を公開する。無効なら両方のキーを消す。クッキーに `_kaisatsu_uid` を偽装して入れても、毎回 DB で確認し直すため、無視される。
- `UserDirectory` / `Credentials`: アプリ側がユーザー表を差し込む口。

## 依存関係

- `spin.toml` は `cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.1" }`(Git のタグ参照)に依存している。`spin test` は、このタグで 7/7 通る。開発中は `path = "../CyberTrain"` に替えて本体の最新を試してもよい。
- `cybertrain/kaisatsu.rb` は純粋な部分だけ(フレームワーク不要)。DB・ミドルウェアを含む全体は `cybertrain/kaisatsu/full` を読む。

## テスト

- `pbkdf2` / `password_hash` / `token`: CRuby でスナップショットを作り、Spinel で比較する。
- `stores` / `authenticator` / `gate_chain`: SQLite を FFI で使うので CRuby では動かない。`script/regen-snapshot test/<name>.rb` でバイナリの出力から作る。
- `gate_chain` は実際の積み方(`SessionStore` → `Gate` → `Router`)で、`Test::Client` のクッキー往復を含めて確認する。

## Spinel で踏んだ点(アプリ側の注意)

- **クラス変数(`@@x`)の配列は、ガベージコレクションの後に別の配列と同じものになることがある。** 起動時に大量の文字列を作る(例: `PasswordHash.create`、300,000 回のループ)と、そのあとで登録した `Router` のルート配列が、テストハーネスの `@@cases` と同じ配列になる。症状は、テスト数が増えることと `undefined method 'block' for Route`。
  - 再現: `spikes/m2_cvar_gc_repro.rb`(改札のコードを使わず、本体の `Router` と自前の `@@cases` だけで出る)。`@@cases` をモジュールレベルのインスタンス変数 `@cases` に替えると消える。
  - 影響範囲: CyberTrain 本体で `@@` を代入しているのは `cybertrain/test.rb`(テストハーネス)だけ。実行時のフレームワークは影響を受けない。改札のライブラリ本体は `@@` を使っていない。
  - 対応: 改札のテストハーネスはクラス変数をやめ、定数が持つ 1 つのオブジェクトに状態を置いた。本体の `cybertrain/test.rb` は本体側で直す必要がある(下記)。ポスタルのハーネスも同じ書き方なので、同様に直すこと。
  - 本体への報告: https://github.com/saeki-mototsune/CyberTrain/issues/26
  - 本体への報告案(参考): 「`test.rb` の `@@cases` などを、規則 18 の推奨どおりモジュールレベルの `@` 変数かオブジェクトに替える」。大量に割り当てる処理(パスワードハッシュなど)を起動時に行うテストで出る。
- ルートのブロックの中で `DB.with` を呼ばず、通常のメソッドから呼ぶ(`spikes/NOTES.md` 規則 32・45)。
- `Authenticator.new(directory)` の引数は、あらかじめ変数か定数に束縛しておく(規則 58)。

## 次にやること

1. 生成コマンド(`cybertrain generate kaisatsu`): users テーブル、`UserDirectory` の実装、ログイン/ログアウトのコントローラとビュー。
2. パスワード再設定の流れ(`TokenStore` + ポスタルの通知差し込み口 `Notifier`)。
3. CyberTrain のブログ例への組み込み。

## `require "openssl"` を入れたバイナリでは Web サーバーが動かない

`config/app.rb` に `require "openssl"` を足すだけで、アプリのすべてのリクエストが `NoMethodError: undefined method 'getbyte' for an instance of String` で 500 になる(`require "socket"` だけなら 200)。CyberTrain 本体が `openssl` パッケージを避けているのは、このためと思われる。SMTP の TLS には OpenSSL が必要なので、ポスタルのメール送信は、Web とは別のバイナリ(`bin/mail_worker.rb`)に分けた。Web 側は `cybertrain/postal`(OpenSSL を読まない中核部分)のスプールに書くだけ。詳細は Issue #2。

**原因**(本体の Issue #27 のコメントに、CyberTrain を使わない最小の再現つきで書いた): `openssl` に限らず、Spinel 2026.09.12 では、**どれかのクラスが `getbyte` という名前のメソッドを定義すると、多相の(型が一つに決まらない)受け手への `x.getbyte(i)` が、受け手が `String` のときに `NoMethodError` になる**。組み込みの `String#getbyte` が、ユーザー定義の `getbyte` だけの表に置き換わるように見える。`openssl` パッケージは `OpenSSL::Buffering#getbyte` を定義しているので、読み込むだけで起きる。自前のクラスに `def getbyte` を書いただけ(`openssl` なし、一度もインスタンス化しなくても)でも同じ。受け手が `String` と確定している呼び出しは問題ない。CyberTrain 本体には `getbyte` の呼び出しが 9 ファイル 24 か所ある。他の組み込みメソッド名(`size`、`bytesize` など)で同じことが起きるかは、試していない。本体への報告: https://github.com/saeki-mototsune/CyberTrain/issues/27

### 上流で直った後の確認(CyberTrain main `cb83688`、Spinel 2026.09.12)

#26 と #27 は CyberTrain 本体の main で修正された(512d667、d459d6e。v0.2.1 の後のタグはまだない)。main に対して次を確かめた。

- `spin test`: 9/9 が通る(`spin.toml` の `cybertrain` を `ref = "main"` にして実行)。
- `config/app.rb` に `require "openssl"` を足した新規アプリは、開発サーバーでも本番ビルド(`cybertrain build`)でも、日本語のクエリ・ヘッダー付きの要求が 200 で通り、`ab` 2,000 件で失敗は 0 だった。
- 改札とポスタルを入れたカンバンアプリ(Yucky39/kanban)で、Web バイナリに `cybertrain/postal/smtp_factory`(OpenSSL)をリンクし、確認メールをスレッド上で Mailpit に直接送る実験をした。`script/verify` は開発サーバー・本番ビルドとも 42/42 で、確認メールは 2 通届いた。`ab` で `GET /login` を 20 並列・3,000 件、失敗 0、毎秒約 20,000 件、メモリ約 14 MB。
- **`require "openssl"` は `config/app.rb` の先頭に置く。** `cybertrain/kaisatsu/full` や `cybertrain/postal/smtp_factory` の後に `openssl` が読まれる並びだと、ビルドが `openssl/digest.rb:40: unsupported call ... sha256_bin` で止まった(`openssl` を先頭にすると通る)。原因の切り分けは途中で、Spinel 側の定数の解決順に関わると思われる。
- したがって、ワーカーを分ける理由は「動かない」から「分けたいなら分ける」に変わる。分離の既定は変えていない(メールの再試行と配達の記録が Web の再起動と無関係になる利点は残る)。Web バイナリから直接送る構成は、タグが切られてから既定にするか決める。
- Spinel 本体: ユーザー定義の `getbyte` などが組み込みメソッドを隠す問題は、matz/spinel#4816 として報告済みで、master で修正されている(2026-09-22)。Spinel 2026.10.25 をビルドして、再現コード(`Reader#getbyte` を定義し、`["abc", 42]` の要素に `getbyte(0)` を呼ぶ)が 2026.09.12 の `NoMethodError` から `97` になることを確かめた(`bytesize` も同様)。新しく報告する必要はない。ただし CyberTrain main は Spinel 2026.10.25 ではまだ使えない: `spin test` は 87/98(2026.09.12 では 97/98。差の 10 件は CyberTrain の docs/spinel-feedback.md にある「Regressions in newer packages」と同じ)で、カンバンアプリは `migration.rb:173: a constant write given a Hash ...` でビルドが拒否される。当面は Spinel 2026.09.12 のままにする(CyberTrain#27 のコメントに詳細)。

### CyberTrain v0.3.0 / Spinel 2026.10.26.7019 での確認(2026-10-27)

CyberTrain 本体の #27 に先方(saeki-mototsune)から返信があり、v0.3.0 が固定する Spinel(フォーク版 2026.10.26.7019)で、前に挙げた退行は直っているとのことだったので、改札・ポスタル・カンバンで確かめた。

- ポスタル: `spin test` 10/10、`integration/run-mailpit` の全項目が通る。
- 改札: そのままだと `spin test` は 8/9 で、`gate_chain.rb` が 5 件 `undefined method 'ok?' for an instance of Cybertrain::Kaisatsu::LoginResult` で落ちた。生成コントローラのカンバンも `spin build` が 3 件拒否された(`unsupported condition (non-bool) ... token_still_valid?`)。どちらも、`Cybertrain::DB.with` ブロックの値を、そのままメソッド呼び出しや `if` に使っているのが原因。この Spinel では、その値の型が決まらず、メソッド呼び出しは実行時に `NoMethodError`、条件は拒否になる。2026.09.12 と、公式の 2026.10.25 では起きない。CyberTrain 本体の DB だけで再現する 30 行ほどのプログラムがある(`LoginResult` のようなクラスを返すブロックの値に `.ok?` を呼ぶ)。
- **直し方**: ブロックの前に、型の決まった変数に仮の値を入れておき、ブロックの中で代入して、ブロックの外で使う(`outcome = LoginResult.new("none", "", ""); DB.with { |conn| outcome = auth.login(...) }; outcome`)。真偽値は `false` で用意する。生成コントローラのテンプレートと `test/gate_chain.rb` をこの形に直した。この形は 2026.09.12 でも通る。
- **生成コントローラの `DB.with` は `Cybertrain::DB.with` と書く。** トップレベルのクラスから裸の `DB` は引けず、この Spinel では `NameError: uninitialized constant SessionsController::DB` で全リクエストが 500 になった(2026.09.12 では定数の解決が緩く、動いていた)。ライブラリ内の `DB` は `module Cybertrain` の中にあるので問題ない。
- 直した後: 改札 `spin test` 9/9(2026.09.12 でも 9/9)、`script/check-installer` 通過、カンバンは本番ビルドで `script/verify` 42/42。Web バイナリに SMTP(OpenSSL)を入れる構成も 42/42 でメール 2 通着信。
- 前に書いた「`require "openssl"` を先頭に置かないとビルドが止まる」は、この Spinel では起きなかった(`cybertrain/postal/smtp_factory` を `cybertrain/kaisatsu/full` の後に置いてビルドが通り、42/42、`GET /login` は約 16,000 件/秒、失敗 0)。

### CyberTrain v0.3.1 / Spinel 2026.10.27.7020 での確認(2026-10-29)

CyberTrain 本体の #90 が、v0.3.1 が固定する Spinel 2026.10.27.7020(matz/spinel#10415)で直った。`Cybertrain::DB.with` ブロックの値が、アプリのクラスの値でもそのまま使える。

- `spin.toml` の `cybertrain` を `ref = "v0.3.1"` にした。改札 `spin test` は回避策を入れたままで 9/9。
- **回避策を外した。** 「ブロックの前に仮の値を入れ、ブロックの中で代入する」形(上の v0.3.0 の節)をやめ、`Cybertrain::DB.with { |conn| ... }` の値をそのまま返す・`if` に使う形に戻した(生成コントローラのテンプレート 8 か所と `test/gate_chain.rb`)。外した後も `spin test` は 9/9。
- 残るもの: 生成コントローラの `Cybertrain::DB.with`(裸の `DB` は引けない)と、ブロックの中で `request` / `ctx` / `params` が使えない点は、この修正とは別の話で、そのまま。
