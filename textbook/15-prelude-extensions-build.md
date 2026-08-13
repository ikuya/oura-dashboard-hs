# 第 15 章 ClassyPrelude・言語拡張・ビルド運用

← [第14章 テストの書き方](14-testing.md) | [目次](README.md) | [第16章 設計を評価する](16-design-review.md) →

> **この章で復習する文法**: 代替 Prelude と `NoImplicitPrelude`、このプロジェクトで使う言語拡張の全一覧、`-Wall` の主な警告、GHCi での型確認、ビルドエラーの読み方

Haskell のソースは、たいてい `{-# LANGUAGE ... #-}` の列から始まります。第 1 章で「拡張の一覧はモジュールの要約」と述べました。この章では実際の使用状況を整理し、日々のビルド作業の実務も扱います。

## 目次

- [15.1 拡張の使用頻度](#151-拡張の使用頻度)
- [15.2 拡張ごとの効用と落とし穴](#152-拡張ごとの効用と落とし穴)
  - [`OverloadedStrings`](#overloadedstrings)
  - [`LambdaCase`](#lambdacase)
  - [`ScopedTypeVariables`](#scopedtypevariables)
  - [`FlexibleContexts`](#flexiblecontexts)
  - [`DerivingStrategies` + `GeneralizedNewtypeDeriving`](#derivingstrategies-generalizednewtypederiving)
  - [`TemplateHaskell` — 忘れると謎のエラー](#templatehaskell-忘れると謎のエラー)
  - [使わなくなった拡張が残ることもある](#使わなくなった拡張が残ることもある)
- [15.3 ClassyPrelude の実像](#153-classyprelude-の実像)
  - [何が変わるか](#何が変わるか)
  - [落とし穴](#落とし穴)
  - [ClassyPrelude を使うべきか](#classyprelude-を使うべきか)
- [15.4 ビルドとエラー読解の実務](#154-ビルドとエラー読解の実務)
  - [ビルドエラーの抽出](#ビルドエラーの抽出)
  - [型を先に確認する](#型を先に確認する)
  - [ビルドが 2 回連続で失敗したら](#ビルドが-2-回連続で失敗したら)
  - [`-Wall` を有効にする](#-wall-を有効にする)
  - [開発時のビルドを速くする](#開発時のビルドを速くする)
- [15.5 この章のまとめ](#155-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 15.1 拡張の使用頻度

`src/`、`test/`、`app/` の全 30 ファイル（`src/` 20 + `test/` 7 + `app/` 3）での使用状況です。

| 拡張 | 使用モジュール数 | 何のために |
|---|---|---|
| `NoImplicitPrelude` | ほぼ全部 | ClassyPrelude を使う |
| `OverloadedStrings` | ほぼ全部 | 文字列リテラルを `Text` として使う |
| `TemplateHaskell` | 多数 | `$logInfo`、ルート生成、モデル生成 |
| `FlexibleContexts` | 多数 | `ReaderT SqlBackend m` を制約に書く |
| `TypeFamilies`, `MultiParamTypeClasses` | Yesod 関連 | フレームワークの型クラス |
| `ScopedTypeVariables` | 数個 | `(e :: IOException)` のような型注釈 |
| `RecordWildCards` | 数個 | `App {..}`、`AppSettings {..}` |
| `LambdaCase` | 数個 | `\case` |
| `DerivingStrategies` + `GeneralizedNewtypeDeriving` | 数個 | newtype の導出制御 |
| `CPP` | 数個 | `#ifdef DEVELOPMENT` |
| `RankNTypes`, `ExplicitForAll` | `Foundation.hs` | `type DB a = forall m. ...` |
| `InstanceSigs` | `Foundation.hs` | インスタンスメソッドに型を書く |
| `QuasiQuotes` | `TestImport.hs` | Yesod のテスト補助 |
| `GADTs`, `DataKinds`, `UndecidableInstances` 他 | `Model.hs` | persistent の生成コードが要求 |

**上位 2 つはほぼ全ファイル、上位 5 つで大半**という分布です。「拡張は最小限に」という原則はありますが、実務では**数個の定番セットが事実上の標準**になります。

`package.yaml` に `default-extensions` としてまとめる手もありますが、このプロジェクトは各ファイルに書いています。**どのファイルが何を必要としているかが見える**利点があり、Yesod の scaffolding もその流儀です。

## 15.2 拡張ごとの効用と落とし穴

### `OverloadedStrings`

```haskell
dailyMetricName Sleep = "sleep"     -- Text として解釈される
```

無いと `pack "sleep"` と書く必要があります。**副作用**として、型が決まらない文字列リテラルで曖昧性エラーが出ることがあります。

```haskell
-- src/Handler/Api.hs:42
A.object ["error" A..= ("APP_PASSWORD not configured" :: Text)]
```

`.=` の右辺は `ToJSON a => a` なので、リテラルだけでは型が決まりません。`:: Text` が必要です。**この注釈だらけの見た目は `OverloadedStrings` の代償**ですが、`Text` 中心のコードでは全体としては得です。

### `LambdaCase`

```haskell
-- src/Sync.hs:263
syncRange = \case
    HeartrateSeries -> syncHeartrateRange
    Daily daily     -> syncDailyRange daily
```

引数に名前を付けずに `case` できます。特に **`where` 節や、関数の最後の引数がパターンマッチのとき**に効きます。

### `ScopedTypeVariables`

```haskell
-- src/Advice.hs:180
Left (_ :: IOException) -> fail' "claude コマンドが見つかりません。..."

-- src/Logging.hs:44
Left (e :: SomeException) -> do
    hPutStrLn stderr $ "WARNING: cannot write log file " ++ path ...
```

**この拡張が必要になったら、例外を捕まえている合図**です。第 7 章で「捕まえる型を絞れ」と述べましたが、絞るには型を書く必要があり、書くにはこの拡張が要る、という連鎖です。

（本来この拡張は「関数のシグネチャに書いた型変数を `where` の中でも使えるようにする」ものですが、実務ではパターンの型注釈のために有効化することが最も多くなります。）

### `FlexibleContexts`

```haskell
-- src/Sync.hs:3
{-# LANGUAGE FlexibleContexts  #-}
```

Haskell 2010 の制約は `C a`（型変数への適用）だけが許されます。`MonadReader SqlBackend m` のように**具体型を含む制約**を書くにはこの拡張が要ります。persistent / Yesod を使うと自然に必要になるので、実質的には定番セットの一部です。

### `DerivingStrategies` + `GeneralizedNewtypeDeriving`

第 4 章で扱いました。`GeneralizedNewtypeDeriving` は「中身の型のインスタンスを盗む」ので、**意味が変わる場合があります**。`deriving newtype` と明示することで、盗んでいることが読み手に見えます。

### `TemplateHaskell` — 忘れると謎のエラー

このプロジェクトの運用メモに明記されている落とし穴です。

```
`$logInfo` 等の TH スプライスを使うモジュールには
{-# LANGUAGE TemplateHaskell #-} が必要。無いと `$` 演算子として解釈され、
原因の分かりにくいパースエラーになる
```

`$logInfo "..."` は、拡張が無いと `$`（関数適用演算子）と `logInfo` に分解されます。エラーメッセージは「変数 `logInfo` が見つからない」や、文脈によっては謎の構文エラーになります。**エラーの原因と場所が離れる典型例**です。新しくログを足すときは、まずファイル先頭の拡張を確認する習慣をつけてください。

### 使わなくなった拡張が残ることもある

```haskell
-- src/Oura.hs:3
{-# LANGUAGE RecordWildCards #-}
```

`Oura.hs` は `RecordWildCards` を宣言していますが、`realClient` はフィールドを個別に書いており、`{..}` を使っていません。**害はありませんが、`-Wall` でも検出されない**ので、掃除は手動になります。拡張の追加は安いが削除は忘れられがち、という一例です。

## 15.3 ClassyPrelude の実像

### 何が変わるか

**(1) `Text` 中心の多相関数。** `length`、`null`、`take`、`filter` などが `MonoFoldable` / `IsSequence` ベースの多相版になります。

```
ClassyPrelude.take :: IsSequence seq => Index seq -> seq -> seq
ClassyPrelude.null :: MonoFoldable mono => mono -> Bool
```

だから `Text` にも `[a]` にも `Map` にも同じ関数が使えます。

```haskell
-- src/Db.hs:73 — Text に対して take
, toPersistValue (take 10 ts)      -- ISO 8601 の先頭 10 文字 = 日付部分
```

標準 Prelude なら `Data.Text.take 10 ts` と qualified import が必要でした。

**(2) 部分関数が隠される。** `head`、`tail`、`last`、`read`、`fromJust` は使えません。代わりに:

| 標準 | ClassyPrelude | 挙動 |
|---|---|---|
| `head` | `headMay` | `Maybe` を返す |
| `head` | `headEx` | 例外を投げる（名前で明示） |
| `last` | `lastMay` / `lastEx` | 同上 |

```haskell
-- src/Db.hs:91
return $ unSingle <$> headMay rows

-- test/DbSpec.hs:46 — テストでは「空なら落ちてほしい」ので Ex 版
field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-01")
```

**「安全版が既定、危険版は `Ex` 付き」** という命名が重要です。危険な操作を書くときに、自分でも気づけます。

**(3) よく使うものが最初から入っている。** `Data.Text`、`Data.Map`、`Control.Monad`、`Data.Maybe`、`UnliftIO`、`Control.Concurrent.STM` などが re-export されます。`ClassyPrelude.Yesod` はさらに Yesod と persistent を含みます（`src/Db.hs:14`、`src/Model.hs:17`）。

### 落とし穴

運用メモにあるとおりです。

```
ClassyPrelude は stderr/formatTime 等を再エクスポートする一方 unsafePerformIO は
しない。追加した import が "redundant" 警告になったら再エクスポート済みを疑う
```

**何が入っていて何が入っていないかは覚えられません。** 対処は簡単で、

1. とりあえず import せずに書いてみる
2. 「見つからない」と言われたら import する
3. 「redundant」と言われたら消す

`-Wall` が両方を教えてくれるので、コンパイラに任せればよい作業です。

もう一つの落とし穴は、**同名で型が違う関数**です。第 9 章の `foldM`、第 13 章の `timeout` がそうでした。

```haskell
import ClassyPrelude hiding (foldM)
import Control.Monad (foldM)

import ClassyPrelude hiding (timeout)
import System.Timeout (timeout)
```

**`hiding` して標準版を使うのは正当な選択**です。「ClassyPrelude を使うと決めたから全部その版を使わねば」と考える必要はありません。

### ClassyPrelude を使うべきか

新規プロジェクトでの選択肢は主に 3 つです。

| 選択 | 特徴 |
|---|---|
| 標準 Prelude | 学習コストゼロ。`Text` 系の qualified import が増える |
| `ClassyPrelude` | 多相的。Yesod scaffolding の既定 |
| `relude` / `rio` | より現代的。安全性重視。ドキュメントが整っている |

このプロジェクトが ClassyPrelude なのは **Yesod の scaffolding がそうだから**です。既存プロジェクトに参加するなら、その流儀に従うのが正解。新規なら `relude` や `rio` も検討に値します。

## 15.4 ビルドとエラー読解の実務

### ビルドエラーの抽出

Stack の出力は長く、Cabal のフッタや警告に埋もれてエラーが見つかりません。運用メモの推奨コマンドがこれです。

```sh
stack build 2>&1 | grep -E '^\S+\.hs:[0-9]+:[0-9]+: error' -A 12
```

`tail` では見えない、というのが実感に基づく知見です。エラー行の 12 行後までを表示することで、GHC の「期待した型／実際の型」まで読めます。

### 型を先に確認する

このプロジェクトの Haskell 規約（`~/.claude/rules/haskell.md`）に明記されている習慣です。

```sh
# 初めて使う関数・型は、コードを書く前に型を見る
printf ':t FUNCTION\n:i TYPE\n' | stack exec ghci -- -v0
```

実例:

```sh
$ printf ':m + ClassyPrelude\n:t groupBy\n:t try\n' | stack exec ghci -- -v0
groupBy :: IsSequence seq => (Element seq -> Element seq -> Bool) -> seq -> [seq]
try :: (MonadUnliftIO m, Exception e) => m a -> m (Either e a)
```

**名前から挙動を推測しない**という原則の実践手段です。`groupBy` は隣接要素のみをグループ化する、`nub` は O(n²)、`fromListWith f` は `f 新 旧` を呼ぶ——これらは名前からは分かりません。

`:i`（info）はインスタンスも表示するので、「この型は `ToJSON` を持っているか」「この変換子は `MonadUnliftIO` か」を調べるのに便利です。

```sh
$ printf ':i MonadUnliftIO\n' | stack exec ghci -- -v0
class MonadIO m => MonadUnliftIO m where
  withRunInIO :: ((forall a. m a -> IO a) -> IO b) -> m b
instance MonadUnliftIO IO
instance MonadUnliftIO m => MonadUnliftIO (ReaderT r m)
```

プロジェクトのモジュールを読み込んで自作関数を試すなら、

```sh
stack ghci oura-dashboard-hs:lib
```

ただし export リストに載っていない関数（`collectGaps` など）は呼べません。**export リストは契約であり、同時に GHCi での試しやすさにも影響する**——第 1 章で述べたトレードオフの実例です。

### ビルドが 2 回連続で失敗したら

同じ規約の中で最も実用的なルールです。

> ビルドが 2 回連続で失敗したら、次の修正を試す前に、関係する API の実際の型を `:t` / `:i` で確認する。同じ誤った仮説に基づく修正を繰り返さない。

型エラーの修正を推測で繰り返すのは、Haskell で最も時間を溶かすパターンです。**3 回目の修正を試みる前に、事実（型）を確認する。**

### `-Wall` を有効にする

```yaml
# package.yaml:61
ghc-options:
- -Wall
- -fwarn-tabs
```

`-Wall` が有効だから、第 3 章の網羅性検査が機能します。**警告を無視しない**運用と組み合わせて初めて意味を持ちます。

主な警告と対処:

| 警告 | 意味 | 対処 |
|---|---|---|
| `-Wincomplete-patterns` | パターンが網羅されていない | ケースを追加（`_` で潰さない） |
| `-Wunused-imports` | import が未使用 | 消す（ClassyPrelude の再エクスポートを疑う） |
| `-Wunused-matches` | 束縛した変数が未使用 | `_` を頭に付ける（`_unused`） |
| `-Wname-shadowing` | 変数名の隠蔽 | 名前を変える |
| `-Wmissing-signatures` | トップレベルに型がない | 型を書く（外すなら理由をコメントに） |

さらに厳しくするなら `-Wcompat`（将来の変更への備え）、`-Widentical-cases`、`-Wredundant-constraints` があります。導入すると既存コードに警告が出るので、**新規モジュールから段階的に**入れるのが現実的です。

### 開発時のビルドを速くする

```yaml
# package.yaml:58
when:
- condition: (flag(dev)) || (flag(library-only))
  then:
    ghc-options: [-Wall, -fwarn-tabs, -O0]
    cpp-options: -DDEVELOPMENT
  else:
    ghc-options: [-Wall, -fwarn-tabs, -O2]
```

開発時は `-O0`（最適化なし）でコンパイルを速く、本番は `-O2` で実行を速く。**Haskell は最適化を上げるとコンパイルが目に見えて遅くなる**ので、この使い分けは実用的です。

`yesod devel` と組み合わせるとファイル保存時に再コンパイル・再起動されます。`app/DevelMain.hs` は GHCi 内でサーバーを起動し直す仕組み（`foreign-store` で状態を保持）で、さらに速い反復が可能です。

## 15.5 この章のまとめ

- 拡張の一覧はモジュールの要約。定番セット（`NoImplicitPrelude`, `OverloadedStrings`, `TemplateHaskell`, `FlexibleContexts`, `LambdaCase`, `ScopedTypeVariables`, `RecordWildCards`）を覚える。
- `TemplateHaskell` を忘れると `$logInfo` が謎のエラーになる。
- `ScopedTypeVariables` が要る＝例外を捕まえている合図。
- ClassyPrelude は `Text` 中心・部分関数を隠す・re-export が多い。何が入っているかはコンパイラに聞く。
- 同名で型が違う関数は `hiding` して標準版を使ってよい。
- ビルドエラーは `grep -E '... error' -A 12` で抽出する。
- 初めて使う API は `:t` / `:i` で型を確認してから書く。名前から推測しない。
- ビルドが 2 回連続で失敗したら、修正を試す前に型を確認する。
- `-Wall` を有効にし、警告を消す運用にする。開発は `-O0`、本番は `-O2`。

### 文法チェックリスト

| 構文・設定 | 意味 | 本章での実例 |
|---|---|---|
| `NoImplicitPrelude` | 標準 Prelude を自動 import しない | 全ファイル |
| `OverloadedStrings` | リテラルを `Text` などに | 全ファイル |
| `FlexibleContexts` | 具体型を含む制約を書ける | `Sync.hs`, `Db.hs` |
| `ScopedTypeVariables` | パターン内の型注釈 | `Advice.hs`, `Logging.hs` |
| `headMay` / `headEx` | 安全版／例外版 | `Db.hs` / `DbSpec.hs` |
| `import M hiding (f)` | 同名衝突の回避 | `foldM`, `timeout` |
| `-Wall` / `-Wincomplete-patterns` | 警告の有効化 | `package.yaml` |
| `:t` / `:i` | GHCi での型・インスタンス確認 | 日常運用 |
| `-ddump-splices` | TH 生成コードの確認 | 第 12 章 |

---

← [第14章 テストの書き方](14-testing.md) | [目次](README.md) | [第16章 設計を評価する](16-design-review.md) →
