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
- `static/*.js` の変更はブラウザの通常リロードでは反映されない（素の ES モジュール
  ＋ yesod-static のキャッシュヘッダ）。`index.html` だけ更新されるため「枠は出るが
  中身が空」というサーバ側の不具合に見える。`Ctrl+Shift+R` が必要。配信内容そのものの
  確認は `fetch(url, {cache:"reload"})` が速い。フロント変更を伴う作業は、完了報告にも
  ハードリロードを明記する

