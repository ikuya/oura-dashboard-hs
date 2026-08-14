# 実践 Haskell 読本 — 動くアプリで文法と設計を同時に固める

この教材は、実際に動いている Haskell アプリケーション **oura-dashboard-hs**（Oura Ring の生体データを SQLite に同期し、JSON API として配信する Yesod アプリ）を題材に、

1. **Haskell の文法をもう一度整理し**、
2. **その文法が実務のコードでどう使われ、なぜそう書かれているか**

を同時に学ぶためのものです。引用するコードはすべてこのリポジトリの実物です（`src/Metric.hs:50` のように出典を示します。行番号はずれうるので、関数名でも探せるようにしてあります）。

## 対象読者

- 入門書を一度読んだが、`ReaderT SqlBackend m` や `MonadUnliftIO` が並ぶ実物のコードで手が止まる人
- 文法は「見れば分かる」が「自分では選べない」段階の人
- Haskell を書いた経験はあるが、アプリ全体の組み立て方を体系的に見たことがない人

圏論の知識は不要です。SQL と HTTP の基礎、そして「モナドとは何かを一度は読んだ」程度の記憶があれば十分です。

## この教材の方針

**架空のサンプルを使いません。** 文法の説明にも、このリポジトリに実在する式を使います。「この構文は実務でどう出てくるのか」が同時に分かるようにするためです。

**文法と設計を分けません。** `newtype` の説明は「`newtype` とは何か」で終わらず、「なぜここで `newtype` を選び、`deriving newtype (ToJSON)` にしたのか。`stock` にしていたら何が壊れたか」まで書きます。文法は選択肢を与えるだけで、選ぶのは設計だからです。

**良い所だけを見せません。** このコードベースには既知の弱点があります（`docs/code-overview.md` の「潜在的な改善点」）。それらは第 16 章で、なぜそうなったか・どう直すかまで含めて講評します。

**型を先に読みます。** 関数を読むときは実装より先にシグネチャを読む習慣をつけます。GHCi での確認手順も併記します。

演習問題はありません。各章の末尾には、代わりに**まとめ**と**文法チェックリスト**（その章で出た構文の一覧）を置きます。

## 目次

| 章 | タイトル | 主に復習する文法 | 主な題材 |
|---|---|---|---|
| [01](01-reading-a-haskell-project.md) | Haskell のソースを読む | モジュール・import・export・LANGUAGE プラグマ・レイアウト | プロジェクト全体 |
| [02](02-functions-and-patterns.md) | 関数・パターン・演算子 | 関数定義、パターンマッチ、ガード、`where`/`let`、`$` `.` `<$>` `=<<` | `Metric.hs`, `Json.hs`, `Sync.hs` |
| [03](03-adt-and-exhaustiveness.md) | 代数的データ型と網羅性 | `data`、`case`、`\case`、`deriving`、`Enum`/`Bounded` | `Metric.hs` |
| [04](04-newtype-and-records.md) | newtype とレコード | `newtype`、レコード構文、レコード更新、deriving 戦略 | `DateText.hs`, `Oura.hs` |
| [05](05-typeclasses.md) | 型クラスと制約 | `class`/`instance`、制約、多相、`IsString`、孤児インスタンス | `DateText.hs`, `Settings.hs`, `Foundation.hs` |
| [06](06-pure-core-effect-shell.md) | 純粋な芯と効果の殻 | `do` 記法の正体、`Maybe` の `do`、参照透過 | `Sync.hs`, `Advice.hs` |
| [07](07-failure-modes.md) | 失敗の表現を選ぶ | `Maybe`/`Either`/例外/`error`、`try`、`m a` の脱出 | `Oura.hs`, `Handler/Api.hs` |
| [08](08-monad-transformers.md) | モナド変換子と制約の実務 | `ReaderT`、`MonadIO`、`MonadUnliftIO`、型シノニム、`RankNTypes` | `Sync.hs`, `Db.hs`, `Foundation.hs` |
| [09](09-recursion-folds-laziness.md) | 再帰・畳み込み・遅延評価 | リスト内包表記、`foldM`、`go` 再帰、`++` のコスト、正格性 | `Sync.hs`, `Oura.hs`, `Db.hs` |
| [10](10-dependency-injection.md) | 関数のレコードによる依存性注入 | 高階関数、部分適用、クロージャ、レコード更新 | `Oura.hs`, `test/SyncSpec.hs` |
| [11](11-aeson.md) | aeson で緩い JSON を扱う | `Value`、`FromJSON` の手書き、`RecordWildCards` | `Json.hs`, `Settings.hs` |
| [12](12-persistent-and-yesod.md) | persistent と Yesod | Template Haskell、型族、型安全ルーティング | `Model.hs`, `Foundation.hs` |
| [13](13-concurrency.md) | 並行処理とリソース管理 | `TVar`/STM、`forkIO`、`timeout`、`ScopedTypeVariables` | `Advice.hs` |
| [14](14-testing.md) | テストの書き方 | hspec、型推論に任せる判断、スタブ | `test/*.hs` |
| [15](15-prelude-extensions-build.md) | ClassyPrelude・拡張・ビルド運用 | 代替 Prelude、拡張一覧、`-Wall`、GHCi の使い方 | `package.yaml` 他 |
| [16](16-design-review.md) | 設計を評価する | （文法の新出なし） | 既知の弱点 9 件の講評 |

順に読むのが基本です。文法の復習が主目的なら 01〜09、設計の検討が主目的なら 03、04、06、07、10、16 を拾い読みしてください。

## 動かしながら読む

```sh
# ビルド（初回は依存の取得に時間がかかります）
stack build

# テスト
stack test

# ライブラリの関数の型を確かめる（この教材で最も多用する操作）
printf ':m + ClassyPrelude\n:t groupBy\n' | stack exec ghci -- -v0
```

プロジェクト自身の関数・型を確かめるときは、ライブラリを読み込んだ GHCi を使います:

```sh
stack ghci oura-dashboard-hs:lib
# 読み込み後に :t findMissingRange や :i SyncResult など
```

手元でアプリを起動して確認する場合の注意（`.claude/CLAUDE.md` より）:

- `SECRET_KEY` が未設定だと起動時に `error` で落ちます。
- 認証を伴う確認には `APP_PASSWORD` に bcrypt ハッシュを渡します（`.env` の値はハッシュなのでログインには使えません）。
- 本番 DB (`oura.db`) を壊さないよう、`YESOD_SQLITE_DATABASE` に複製を指定してください。

## 対象コードのバージョン

`refactor/haskell-idioms` ブランチのマージ後（コミット `2c61efc` 以降）の状態を前提にしています。全体像の要約は `docs/code-overview.md` にあります。
