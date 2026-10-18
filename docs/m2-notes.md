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

- 起動時(トップレベル)に `PasswordHash.create` を呼び、その結果でユーザー参照を作ってからルートを登録すると、テストハーネスの配列にルートが紛れ込む現象が出た(テスト数が 6 から 10 に増え、`undefined method 'block' for Route` が出る)。固定のハッシュ文字列に変えると消える。リクエスト処理中(ルート登録後)に `PasswordHash.create` を呼んでも問題は出なかった(同じテストで確認済み)。
  - 原因は未特定。メモリの扱い(`spikes/NOTES.md` 規則 58 の系統)の可能性がある。`SPINEL_ALLOC_REPORT` や ASan ビルドで追う余地がある。
  - 当面の回避: 起動時にハッシュを作らない。作るなら、ルート登録の後に行う。
- ルートのブロックの中で `DB.with` を呼ばず、通常のメソッドから呼ぶ(`spikes/NOTES.md` 規則 32・45)。
- `Authenticator.new(directory)` の引数は、あらかじめ変数か定数に束縛しておく(規則 58)。

## 次にやること

1. 起動時ハッシュの現象の原因調査(上記)。
2. 生成コマンド(`cybertrain generate kaisatsu`): users テーブル、`UserDirectory` の実装、ログイン/ログアウトのコントローラとビュー。
3. パスワード再設定の流れ(`TokenStore` + ポスタルの通知差し込み口 `Notifier`)。
4. CyberTrain のブログ例への組み込み。
