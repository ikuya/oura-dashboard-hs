# Coding Guidelines

## Haskell                                                                                

- 初めて使う関数・型は、コードを書く前に `ghci` で型を確認する:
  `printf ':t 関数名\n:i 型名\n' | stack exec ghci -- -v0`
- 関数名から挙動を推測しない。特に馴染みのないライブラリは、名前が期待と違う意味を持つことがある（例: `newFileLoggerSet` はローテーションしない）
- ビルドエラーが2回続いたら、次の修正を試す前に該当APIの型を確認する。同じ誤った仮説で修正を繰り返さない
- `$logInfo` 等の TH スプライスを使うモジュールには
  `{-# LANGUAGE TemplateHaskell #-}` が必要。無いと `$` 演算子として解釈され、原因の分かりにくいパースエラーになる

