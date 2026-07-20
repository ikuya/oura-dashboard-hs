# Coding Guidelines

- `$logInfo` 等の TH スプライスを使うモジュールには
  `{-# LANGUAGE TemplateHaskell #-}` が必要。無いと `$` 演算子として解釈され、原因の分かりにくいパースエラーになる
- `ClassyPrelude` は `stderr`/`formatTime` 等を再エクスポートする一方 `unsafePerformIO` は
  しない。追加した import が "redundant" 警告になったら再エクスポート済みを疑う

## Build / Test

- ビルドエラーの抽出: `stack build 2>&1 | grep -E '^\S+\.hs:[0-9]+:[0-9]+: error' -A 12`
  （`tail` だと Cabal のフッタと警告に埋もれて見えない）
- 手動起動には `SECRET_KEY` が必須（未設定だと起動時 error）。認証が要る動作確認では
  `APP_PASSWORD` に bcrypt ハッシュを渡す。`.env` の値はハッシュなのでログインには使えない:
  `python3 -c "import bcrypt; print(bcrypt.hashpw(b'PASS', bcrypt.gensalt(rounds=10)).decode())"`
- 動作確認は本番 `oura.db` を避け、`YESOD_SQLITE_DATABASE` に複製を指定する

