# Coding Guidelines

- `$logInfo` 等の TH スプライスを使うモジュールには
  `{-# LANGUAGE TemplateHaskell #-}` が必要。無いと `$` 演算子として解釈され、原因の分かりにくいパースエラーになる
- `ClassyPrelude` は `stderr`/`formatTime` 等を再エクスポートする一方 `unsafePerformIO` は
  しない。追加した import が "redundant" 警告になったら再エクスポート済みを疑う

## Build / Test

- ビルドエラーの抽出: `stack build 2>&1 | grep -E '^\S+\.hs:[0-9]+:[0-9]+: error' -A 12`
  （`tail` だと Cabal のフッタと警告に埋もれて見えない）
- 手動起動には `SECRET_KEY` が必須（未設定だと起動時 error）。認証が要る動作確認では
  `APP_PASSWORD` に bcrypt ハッシュを渡す。`.env` の値はハッシュなのでログインには使えない。
  検証用途なら `config/test-settings.yml` のハッシュ（平文は `test-password`）を流用するのが
  速い。新規生成は README.md の手順で（python の `bcrypt` モジュールは入っていない）
- 動作確認は本番 `oura.db` を避け、`YESOD_SQLITE_DATABASE` に複製を指定する
- `static/*` と `index.html` は `Cache-Control: no-cache` で配信している
  （`Application.revalidating`）ので、通常リロードで反映される。ただし ETag は起動時に
  計算されるため、`static/*.js` を変えたらサーバの再起動が必要。再起動前の古い
  ブラウザキャッシュ（1 年 max-age 時代のもの）が残っていれば一度だけ `Ctrl+Shift+R`

