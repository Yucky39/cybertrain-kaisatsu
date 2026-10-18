# M0 検証結果

環境: Spinel 2026.09.12(`cybertrain setup` で `~/.cybertrain` にビルド)、macOS arm64。
コードは `spikes/` にある。ビルドは `spinel spikes/<name>.rb -o build/<name>`。

## 結果

| 項目 | 結果 |
| --- | --- |
| PBKDF2-HMAC-SHA256 を Ruby(`Digest::SHA256.digest` の上)で実装 | 動作。4096 回の値が既知の答え(`c5e478d5...`)と一致。10万回の値も CRuby の OpenSSL と一致 |
| 速度(Spinel) | 4096 回 約 5 ms、10万回 約 0.09 s、60万回 約 0.49 s。CRuby は 4096 回で約 18 ms(60万回なら数秒) |
| `SecureRandom.random_bytes` / `hex` | 動作。呼び出しごとに異なる値 |
| 同梱 `openssl` パッケージ | 既定のビルドでは `ld: library 'ssl' not found`。Homebrew の openssl@3 のパスを渡す必要がある(ポスタルの M0 と同じ)。本ライブラリでは使わない |

## 結論

- パスワードハッシュは方針 A(Ruby の PBKDF2-HMAC-SHA256)で進める。FFI(libsodium など)は不要。
- 既定の反復回数は 600,000(OWASP の推奨)。Spinel で約 0.5 秒。ハッシュ文字列に回数を含め、`needs_rehash?` でログイン時に引き上げる。
- ハッシュ計算中はワーカーを約 0.5 秒占有する。CyberTrain の既定は `SPINEL_WORKERS=1` なので、認証を使うアプリは 2 以上にする前提とする(設計メモ §4)。実測はサーバ結合後(M2)に行う。
- パスワードの Unicode 正規化(NFKC)は行っていない。入力のバイト列をそのまま使う。

## 未検証(M2 で確認)

- `SPINEL_WORKERS` を増やしたときの、ログイン処理中の他リクエストへの影響。
- CyberTrain の Session / Controller / DB との結合。
