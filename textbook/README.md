# 実践 Haskell 教則本 — oura-dashboard-hs を読み書きしながら学ぶ

この教材は、実際に動いている Haskell アプリケーション **oura-dashboard-hs**（Oura Ring の生体データを SQLite に同期し、JSON API として配信する Yesod アプリ）を題材に、**実務で通用する Haskell の書き方**を学ぶためのものです。

入門書が終わったあと、「文法は分かったが、実際のアプリはどう組み立てるのか」で止まっている人を対象にしています。

## この教材の方針

1. **架空のサンプルを使わない。** 引用するコードはすべてこのリポジトリの実物です（`src/Metric.hs:50` のように出典を示します）。
2. **「なぜそう書くか」を必ず書く。** 動く書き方は複数あります。採用した書き方と、採用しなかった書き方を並べて比較します。
3. **良い所だけを見せない。** このコードベースには既知の弱点もあります（`docs/code-overview.md` の「潜在的な改善点」）。それらは第 13 章の演習として、直す対象にします。
4. **型を先に読む。** 関数を読むときは実装より先にシグネチャを読む習慣をつけます。GHCi での型確認手順も併記します。

## 前提知識

- Haskell の基本文法（代数的データ型、型クラス、`do` 記法、`Maybe`/`Either`）
- モナドが「何かを包んだ計算をつなぐ仕組み」であること（圏論的な理解は不要）
- SQL と HTTP の基礎

逆に、以下は知らなくて構いません。教材の中で扱います。

- モナド変換子（`ReaderT`）、`MonadIO` / `MonadUnliftIO` などの制約
- Template Haskell、`persistent`、`Yesod`
- `ClassyPrelude`、STM、`forkIO`

## 目次

| 章 | タイトル | 主な題材 |
|---|---|---|
| [01](01-project-tour.md) | プロジェクトの歩き方と設計の骨格 | モジュール構成、依存の向き、export リスト |
| [02](02-types-over-strings.md) | 文字列を型にする — newtype と ADT | `Metric.hs`, `DateText.hs` |
| [03](03-pure-core-io-shell.md) | 純粋な芯と効果の殻 | `extractScore`, `collectGaps`, `buildAdvicePrompt` |
| [04](04-failure-modes.md) | 失敗の表現を選ぶ — Maybe / Either / 例外 | `parseDayText`, `OuraError`, `tryOura` |
| [05](05-monads-and-constraints.md) | モナドと型クラス制約の実務 | `ReaderT SqlBackend m`, `MonadUnliftIO`, `MonadLogger` |
| [06](06-records-of-functions.md) | 関数のレコードによる依存性注入 | `OuraClient`, `AppLog` |
| [07](07-recursion-and-folds.md) | 再帰・畳み込み・データ変換 | `foldRanges`, `collectGaps`, `syncHeartrateRange` |
| [08](08-json-with-aeson.md) | aeson で緩い JSON を扱う | `Json.hs`, `Settings.hs` の `FromJSON` |
| [09](09-persistent-and-yesod.md) | persistent と Yesod の型駆動 Web | `Model.hs`, `Foundation.hs`, `Handler/*` |
| [10](10-concurrency.md) | 並行処理とリソース管理 | `TVar`, `forkIO`, `timeout`, 子プロセス |
| [11](11-testing.md) | テストの書き方 | `hspec`, インメモリ SQLite, スタブ, `yesod-test` |
| [12](12-prelude-and-extensions.md) | ClassyPrelude・言語拡張・ビルドの実務 | 拡張の意味、`-Wall`、GHCi での型確認 |
| [13](13-exercises.md) | 演習 — 実在する弱点を直す | 既知の改善点 6 件＋解答例 |

順に読むのが基本ですが、02 → 04 → 05 → 06 の 4 章がこの教材の核です。時間がなければそこだけでも構いません。

## 動かしながら読む

```sh
# ビルド（初回は依存の取得に時間がかかります）
stack build

# テスト
stack test

# 型を確かめる（この教材で最も多用する操作）
printf ':t findMissingRange\n:i DailyMetric\n' | stack exec ghci -- -v0
```

GHCi でプロジェクトのモジュールを読み込む場合:

```sh
stack ghci oura-dashboard-hs:lib
```

手元でアプリを起動して確認する場合の注意（`.claude/CLAUDE.md` より）:

- `SECRET_KEY` が未設定だと起動時に `error` で落ちます。
- 認証を伴う確認には `APP_PASSWORD` に bcrypt ハッシュを渡します。
- 本番 DB (`oura.db`) を壊さないよう、`YESOD_SQLITE_DATABASE` に複製を指定してください。

## 対象コードのバージョン

`docs/code-overview.md` と同じく、`refactor/haskell-idioms` ブランチのマージ後（コミット `2c61efc` 以降）の状態を前提にしています。行番号は変わりうるので、引用箇所は関数名でも探せるようにしています。
