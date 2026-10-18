# cybertrain-kaisatsu(改札)設計メモ(初版・ドラフト)

調査元は saeki-mototsune/CyberTrain(Spinel 2026.09.12 向け、v0.2.1、pre-alpha)の README、docs/design.md、spikes/NOTES.md、cybertrain/crypto.rb、cybertrain/session.rb などである。
SMTP ライブラリ(ポスタル)は別リポジトリ(cybertrain-postal)で扱い、本書は認証(改札)に関する部分だけを載せる。

## 1. 前提(CyberTrain 側の事実)

- 言語は Ruby。アプリは CRuby では動かさず、Spinel で単一ネイティブバイナリにコンパイルする。実行時に gem は使えない。
- ライブラリは spin パッケージ(spin.toml の `[package]`)として配布する。
- メタプログラミング(`send` / `instance_exec` / `method_missing` / `define_method` / `eval`)は使わない。Rails 風の語彙が必要な箇所は、ビルド時に生成した素の Ruby で実現する。
- テストは `test/<name>.rb` と `test/<name>.rb.expected`(スナップショット)で、`spin test` が比較する。minitest / RSpec は使えない。`require "cybertrain/test"` が必須である。
- CyberTrain 本体の「やらないこと」に認証が入っている(README / docs/design.md §2.3)。改札はそこを埋めるライブラリになる。
- セッションはクッキーストアで HMAC-SHA256 署名(cybertrain/session.rb)。値は String のみ。CSRF 対策のミドルウェアがある。
- HMAC-SHA256、定数時間比較(`Crypto.secure_compare`)、ランダムトークン(`Crypto.random_token`)は cybertrain/crypto.rb にある。`openssl` パッケージは使っていない。
- Spinel の README に、bcrypt / argon2 / scrypt の記載はない。FFI と、パッケージが `.c` を持てることは明記されている。

## 2. 方針

- 名前空間は `Cybertrain::Kaisatsu`。ファイルは `cybertrain/kaisatsu.rb` と `cybertrain/kaisatsu/*.rb` に置く。
- 改札は CyberTrain の Controller / Session / DB に依存する。ポスタルへは直接依存せず、通知用の差し込み口(§6)を経由する。
- spikes/NOTES.md の規則 1〜59 を制約として扱う。特に効くもの:
  - 規則 1・2: 非リテラルの `send` と、保存したブロックの `instance_exec` は使わない。
  - 規則 3・10・34: 基底クラスに抽象スタブを置く。同名メソッドは戻り値の型も揃える。
  - 規則 35: 渡されたオブジェクトへの `obj[k] = v` ではなく、型付きのインスタンスメソッドで変更する。
  - 規則 40・42: 独自メソッドに `call` を使わない。lambda をキーワード引数で渡さない。
  - 規則 47・53・54: 例外は階層で見分けられない。`rescue` 句の列挙とクラス名で見分ける。
  - 規則 57: リクエスト経路でプロセス全体の `Mutex` を取らない。
  - 規則 58: `Foo.new(その場で作った文字列)` は避け、ローカル変数に束縛してから渡す。
- 全体を require する統合テストを 1 本置く(規則 36・41)。

## 3. 責務

- 責務: パスワードの保存と検証、ログイン・ログアウト、サーバ側セッション、トークン(パスワード再設定・メール確認・API)、ログイン試行の制限、CyberTrain への組み込み(生成コード + ミドルウェア `Gate`)。
- 非責務(初版): OAuth / パスキー / TOTP。必要になった時点で別マイルストーンとする。

## 4. パスワードハッシュ(最大の技術リスク)

選択肢は次の 2 つ。

- A. PBKDF2-HMAC-SHA256 を Ruby で実装する(`Crypto.hmac_digest` の上)。依存は増えないが、推奨反復回数(OWASP は SHA-256 で 600,000 回)を Ruby の実装で回すと遅い可能性が高い。実測が必要。
- B. FFI で libsodium の argon2id(`crypto_pwhash`)または libcrypto の `PKCS5_PBKDF2_HMAC` を呼ぶ。速度と安全性は最良だが、ビルド要件が増える。

まず A を実測し、実用範囲か判断する。不足なら B を採る。どちらでも、ハッシュ文字列は自己記述的な形式(例: `$pbkdf2-sha256$i=...$salt$hash`)にして、ログイン成功時に古いパラメータを検知して再ハッシュできるようにする。

- パスワード検証は CPU を長く使う。CyberTrain の既定は `SPINEL_WORKERS=1` なので、計算中は他のリクエストが止まる(規則 22・57)。認証を使うアプリは `SPINEL_WORKERS` を 2 以上にする前提をドキュメントに書く。
- 比較は `Crypto.secure_compare` を使う。
- 存在しないユーザーでも同じコストのダミー検証を行い、応答時間とメッセージでアカウントの有無を漏らさない。

## 5. セッションとトークン

- CyberTrain のクッキーストアのセッションは、サーバ側から失効できない。改札では、サーバ側のセッション表(ID は 256bit のランダム値、DB にはハッシュだけ保存)を持ち、クッキーのセッションにはその ID だけを載せる。これでログアウトと「全端末ログアウト」が効く。
- ログイン時にセッションを作り直す(固定化攻撃対策)。
- パスワード再設定・メール確認・API トークンは、ランダムな値のハッシュだけを保存し、1 回限り・有効期限つきにする。
- パスワード再設定メールの応答は、アカウントの有無で変えない。送信は応答の後(バックグラウンド)で行う。
- ログイン試行の制限はアカウント単位と IP 単位で、DB のカウンタで実装する。プロセス全体の `Mutex` は使わない(規則 57)。
- パスワードを再設定したら、そのユーザーの全セッションとトークンを失効する。

## 6. CyberTrain への組み込み

- `cybertrain generate kaisatsu` のような生成コマンドで、`users` / セッション / トークンのマイグレーション、モデル、コントローラ、ビューを素の Ruby として出力する。
- `Kaisatsu::Gate`(改札口)は、セッションからユーザーを読み込むミドルウェア。コントローラ側は `before_action { |c| Kaisatsu.require_login(c) }` の形で使う(規則 2 のとおり、ブロックにレシーバを渡す)。
- 通知(再設定メール・確認メール)は `Kaisatsu::Notifier` という抽象クラスに任せる。基底には空の実装を置き、生成アプリでポスタルに結ぶ(規則 3)。改札からポスタルへの直接依存は作らない。

## 7. マイルストーン

- M0: 検証。PBKDF2 の速度、FFI で libsodium / libcrypto が使えるか、`SecureRandom` の品質、`SPINEL_WORKERS` を増やしたときの挙動。
- M1: ハッシュ + トークン + サーバ側セッション(DB なしの純粋部分をスナップショットテスト)。
- M2: 生成コマンド、`Gate`、ログイン制限、CyberTrain のブログ例への組み込み。
- M3: パスワード再設定・メール確認(ポスタルと結合)、全端末ログアウト、監査ログ。
- M4 以降: TOTP、パスキー、外部アカウント連携。

## 8. 未決事項

1. パスワードハッシュ方針(§4 の A / B)。M0 の実測後に決める。
2. 別セッションで決めた用語・API があれば反映する(本書の命名は仮)。
3. ライセンス。CyberTrain 本体は MIT。
4. GitHub リポジトリ(Yucky39/cybertrain-kaisatsu)はまだ無い。ローカルのみ `git init` 済み。
