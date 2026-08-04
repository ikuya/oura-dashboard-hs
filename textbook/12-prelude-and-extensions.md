# 第 12 章 ClassyPrelude・言語拡張・ビルドの実務

Haskell のソースは、たいてい `{-# LANGUAGE ... #-}` の列から始まります。初学者はこれを「おまじない」として読み飛ばしがちですが、**拡張の一覧はそのモジュールが何をしているかの要約**です。この章では、このプロジェクトで使われている拡張を実際の必要性とともに整理し、日々のビルド作業の実務も扱います。

## 12.1 拡張の使用頻度

このプロジェクト（`src/`, `test/`, `app/` の全 20 ファイル）での使用状況です。

| 拡張 | 使用モジュール数 | 何のために |
|---|---|---|
| `NoImplicitPrelude` | 全部 | ClassyPrelude を使う |
| `OverloadedStrings` | 全部 | 文字列リテラルを `Text` として使う |
| `TemplateHaskell` | 15 | `$logInfo`、ルート生成、モデル生成 |
| `FlexibleContexts` | 12 | `ReaderT SqlBackend m` を制約に書く |
| `TypeFamilies`, `MultiParamTypeClasses` | 各 10 | Yesod / persistent の型クラス |
| `ScopedTypeVariables` | 6 | `(e :: IOException)` のような型注釈 |
| `RecordWildCards` | 6 | `App {..}`、`AppSettings {..}` |
| `LambdaCase` | 4 | `\case` |
| `DerivingStrategies` + `GeneralizedNewtypeDeriving` | 各 4 | newtype の導出制御 |
| `CPP` | 3 | `#ifdef DEVELOPMENT` |
| `RankNTypes` | 2 | `type DB a = forall m. ...` |
| `InstanceSigs` | 2 | インスタンスメソッドに型を書く |

**上位 2 つは全ファイル、上位 5 つで大半**という分布です。「拡張は最小限に」という原則はありますが、実務では**数個の定番セットが事実上の標準**になります。

`package.yaml` に `default-extensions` としてまとめる手もありますが、このプロジェクトは各ファイルに書いています。**どのファイルが何を必要としているかが見える**利点があり、Yesod の scaffolding もその流儀です。

## 12.2 覚えるべき拡張とその効用

### `OverloadedStrings`

```haskell
dailyMetricName Sleep = "sleep"     -- Text として解釈される
```

無いと `pack "sleep"` と書く必要があります。**副作用**として、型が決まらない文字列リテラルで曖昧性エラーが出ることがあります。その場合は型注釈を付けます。

```haskell
-- src/Handler/Api.hs:42
A.object ["error" A..= ("APP_PASSWORD not configured" :: Text)]
```

`.=` の右辺は `ToJSON a => a` なので、リテラルだけでは型が決まりません。`:: Text` が必要です。**この注釈だらけの見た目は `OverloadedStrings` の代償**ですが、`Text` 中心のコードでは全体としては得です。

### `LambdaCase`

```haskell
-- src/Metric.hs:51
dailyMetricName = \case
    Sleep -> "sleep"
    ...
```

引数に名前を付けずに `case` できます。特に **`where` 節や引数の最後がパターンマッチのとき**に効きます。

```haskell
-- src/Sync.hs:263
syncRange = \case
    HeartrateSeries -> syncHeartrateRange
    Daily daily     -> syncDailyRange daily
```

### `ScopedTypeVariables`

例外の型を指定するために必要です。

```haskell
-- src/Advice.hs:180
Left (_ :: IOException) -> fail' "claude コマンドが見つかりません。..."

-- src/Logging.hs:44
Left (e :: SomeException) -> do
    hPutStrLn stderr $ "WARNING: cannot write log file " ++ path ...
```

**この拡張が必要になったら、例外を捕まえている合図**です。第 4 章で「捕まえる型を絞れ」と述べましたが、絞るには型を書く必要があり、書くにはこの拡張が要る、という連鎖です。

### `RecordWildCards`

```haskell
-- src/Application.hs:100
let mkFoundation appConnPool = App {..}
```

スコープ内の同名変数からレコードを作ります。**フィールド 9 個の `App` や 20 個の `AppSettings` で威力を発揮**します。

逆方向（分解）にも使えます。

```haskell
-- src/Oura.hs:3 で有効化されているが、現在は使われていない
{-# LANGUAGE RecordWildCards #-}
```

`Oura.hs` は `RecordWildCards` を宣言していますが、実際には `App {..}` のような使い方をしていません（`realClient` はフィールドを個別に書いている）。**使わなくなった拡張が残っている**例です。害はありませんが、`-Wunused-*` 系の警告では検出されないので、掃除は手動になります。

### `DerivingStrategies` + `GeneralizedNewtypeDeriving`

第 2 章で扱いました。newtype の導出方法を明示します。

```haskell
-- src/DateText.hs:33
newtype DayText = DayText { unDayText :: Text }
    deriving stock   (Show)
    deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)
```

**`GeneralizedNewtypeDeriving` は「中身の型のインスタンスを盗む」ので、意味が変わる場合があります。** 例えば `Sum Int` のような `Monoid` を盗むと意図しない結合になりえます。`deriving newtype` と明示することで、「盗んでいる」ことが読み手に見えます。

### `TemplateHaskell` — 忘れると謎のエラー

このプロジェクトの運用メモに明記されている落とし穴です。

```
`$logInfo` 等の TH スプライスを使うモジュールには
{-# LANGUAGE TemplateHaskell #-} が必要。無いと `$` 演算子として解釈され、
原因の分かりにくいパースエラーになる
```

`$logInfo "..."` は、拡張が無いと `$` （関数適用演算子）と `logInfo` に分解されます。エラーメッセージは「変数 `logInfo` が見つからない」や、文脈によっては謎の構文エラーになります。**エラーの原因と場所が離れる典型例**です。

新しくログを足すときは、まずファイル先頭の拡張を確認する習慣をつけてください。

### `CPP`

```haskell
-- src/Settings.hs:83
let defaultDev =
#ifdef DEVELOPMENT
        True
#else
        False
#endif
```

C プリプロセッサです。`package.yaml:65` で `cpp-options: -DDEVELOPMENT` が dev フラグ時に指定されます。

**ビルド構成で挙動を変える**ための仕組みですが、多用すると読みにくくなります。ここでは「開発時の既定値」1 箇所だけに限定されており、妥当な使い方です。

## 12.3 ClassyPrelude の実像

### 何が変わるか

**(1) `Text` 中心。** `length`、`null`、`take`、`filter` などが `MonoFoldable` / `IsSequence` ベースの多相版になります。

```
ClassyPrelude.take :: IsSequence seq => Index seq -> seq -> seq
```

だから `Text` にも `[a]` にも `Vector` にも同じ関数が使えます。

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

-- src/Sync.hs:183
(d:_) | isMissing d -> DateRange d <$> lastMay grp
```

**「安全版が既定、危険版は `Ex` 付き」** という命名になっているのが重要です。危険な操作を書くときに、自分でも気づけます。

テストでは `headEx` が使われています。

```haskell
-- test/DbSpec.hs:44
field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-01")
```

テストでは「空だったら落ちてほしい」ので、これは適切な使い分けです。

**(3) よく使うものが最初から入っている。** `Data.Text`、`Data.Map`、`Control.Monad`、`Data.Maybe`、`UnliftIO`、`Control.Concurrent.STM` などが re-export されます。import が減ります。

`ClassyPrelude.Yesod` はさらに Yesod と persistent を含みます（`src/Db.hs:14`、`src/Model.hs:17`）。

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

もう一つの落とし穴は、**同名で型が違う関数**です。第 7 章の `foldM`、第 10 章の `timeout` がそうでした。

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

このプロジェクトが ClassyPrelude なのは **Yesod の scaffolding がそうだから**です。既存プロジェクトに参加するなら、その流儀に従うのが正解です。新規なら `relude` や `rio` も検討に値します。

## 12.4 ビルドとエラー読解の実務

### ビルドエラーの抽出

Stack の出力は長く、Cabal のフッタや警告に埋もれてエラーが見つかりません。運用メモの推奨コマンドがこれです。

```sh
stack build 2>&1 | grep -E '^\S+\.hs:[0-9]+:[0-9]+: error' -A 12
```

`tail` では見えない、というのが実感に基づく知見です。エラー行の 12 行後までを表示することで、GHC の「期待した型 / 実際の型」まで読めます。

### 型を先に確認する

このプロジェクトの Haskell 規約（`~/.claude/rules/haskell.md`）に明記されている習慣です。

```sh
# 初めて使う関数・型は、コードを書く前に型を見る
printf ':t FUNCTION\n:i TYPE\n' | stack exec ghci -- -v0
```

実例:

```sh
$ printf ':t groupBy\n' | stack exec ghci -- -v0
groupBy :: IsSequence seq => (Element seq -> Element seq -> Bool) -> seq -> [seq]
```

**名前から挙動を推測しない**という原則の実践手段です。`groupBy` は隣接要素のみをグループ化する（ソートしない）、`nub` は O(n²)、`partition` の返り値の順序——これらは名前からは分かりません。

`:i`（info）はインスタンスも表示するので、「この型は `ToJSON` を持っているか」を調べるのに便利です。

```sh
$ printf ':i Single\n' | stack exec ghci -- -v0
newtype Single a = Single {unSingle :: a}
instance PersistField a => RawSql (Single a)
...
```

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

`-Wall` が有効だから、第 2 章の網羅性検査が機能します。**警告を無視しない**運用と組み合わせて初めて意味を持ちます。

主な警告と対処:

| 警告 | 意味 | 対処 |
|---|---|---|
| `-Wincomplete-patterns` | パターンが網羅されていない | ケースを追加（`_` で潰さない） |
| `-Wunused-imports` | import が未使用 | 消す（ClassyPrelude の再エクスポートを疑う） |
| `-Wunused-matches` | 束縛した変数が未使用 | `_` を頭に付ける（`_unused`） |
| `-Wname-shadowing` | 変数名の隠蔽 | 名前を変える |
| `-Wmissing-signatures` | トップレベルに型がない | 型を書く |

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

`yesod devel` と組み合わせると、ファイル保存時に再コンパイル・再起動されます。`app/DevelMain.hs` は GHCi 内でサーバーを起動し直す仕組み（`foreign-store` で状態を保持）で、さらに速い反復が可能です。

## 12.5 この章のまとめ

- 拡張の一覧はモジュールの要約。定番セット（`NoImplicitPrelude`, `OverloadedStrings`, `TemplateHaskell`, `LambdaCase`, `ScopedTypeVariables`, `RecordWildCards`）を覚える。
- `TemplateHaskell` を忘れると `$logInfo` が謎のエラーになる。
- `ScopedTypeVariables` が要る＝例外を捕まえている合図。
- ClassyPrelude は `Text` 中心・部分関数を隠す・re-export が多い。何が入っているかはコンパイラに聞く。
- 同名で型が違う関数は `hiding` して標準版を使ってよい。
- ビルドエラーは `grep -E '... error' -A 12` で抽出する。
- 初めて使う API は `:t` / `:i` で型を確認してから書く。名前から推測しない。
- ビルドが 2 回連続で失敗したら、修正を試す前に型を確認する。
- `-Wall` を有効にし、警告を消す運用にする。開発は `-O0`、本番は `-O2`。

## 演習

1. `src/Oura.hs` の `{-# LANGUAGE RecordWildCards #-}` は現在使われていません。削除してビルドが通ることを確認してください。他にも未使用の拡張が宣言されているファイルがないか調べてください（各拡張がどの構文で必要になるかを整理すると効率的です）。

2. `ClassyPrelude` が `unsafePerformIO` を re-export していないことを GHCi で確認してください。`Data.Map.Strict` は re-export されていますか（`src/Db.hs` が `qualified Data.Map.Strict as M` を明示 import している理由を考えてください）。

3. `-Wall` に加えて `-Wcompat -Widentical-cases -Wredundant-constraints` を有効にすると、どんな警告が新たに出ますか。`package.yaml` を書き換えて `stack build` し、出た警告を分類してください。修正すべきものと無視してよいものを判定してください。
