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

- `spin.toml` は `cybertrain = { path = "../CyberTrain" }`(ローカルのクローン)に依存している。公開前に Git タグ参照へ変える。
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
  - 本体への報告案: 「`test.rb` の `@@cases` などを、規則 18 の推奨どおりモジュールレベルの `@` 変数かオブジェクトに替える」。大量に割り当てる処理(パスワードハッシュなど)を起動時に行うテストで出る。
- ルートのブロックの中で `DB.with` を呼ばず、通常のメソッドから呼ぶ(`spikes/NOTES.md` 規則 32・45)。
- `Authenticator.new(directory)` の引数は、あらかじめ変数か定数に束縛しておく(規則 58)。

## 次にやること

1. 生成コマンド(`cybertrain generate kaisatsu`): users テーブル、`UserDirectory` の実装、ログイン/ログアウトのコントローラとビュー。
2. パスワード再設定の流れ(`TokenStore` + ポスタルの通知差し込み口 `Notifier`)。
3. CyberTrain のブログ例への組み込み。
