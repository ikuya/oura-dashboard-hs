# 第 3 章 代数的データ型と網羅性

← [第2章 関数・パターン・演算子](02-functions-and-patterns.md) | [目次](README.md) | [第4章 newtype とレコード](04-newtype-and-records.md) →

> **この章で復習する文法**: `data` 宣言、直和と直積、`deriving`、`Enum` / `Bounded` と `[minBound .. maxBound]`、`case` と `\case`（`LambdaCase`）、網羅性検査と `-Wall`

Haskell を実務で使う最大の見返りは「型でバグを防ぐ」ことです。ただし、型を書けば自動的にそうなるわけではありません。`Text` と `Text` を取り違えるバグは、型があっても止まりません。

この章では、このプロジェクトが実際に行った **stringly-typed（何でも文字列）からの脱却**を追いかけながら、`data` 宣言の文法と網羅性検査を復習します。題材はコミット `1835052` "Replace stringly-typed metrics, dates and the global logger with types" です。

## 目次

- [3.1 Before: 文字列で持ち回る](#31-before-文字列で持ち回る)
- [3.2 `data` 宣言の文法](#32-data-宣言の文法)
  - [直和（enum 型）](#直和enum-型)
  - [直和 + 直積（コンストラクタが引数を取る）](#直和-直積コンストラクタが引数を取る)
  - [`deriving` — インスタンスの自動導出](#deriving-インスタンスの自動導出)
- [3.3 文字列表現は 1 箇所に置く](#33-文字列表現は-1-箇所に置く)
  - [文法メモ: `\case`（LambdaCase）](#文法メモ-caselambdacase)
- [3.4 網羅性検査を「効かせる」](#34-網羅性検査を効かせる)
- [3.5 `Enum` / `Bounded` で「全部」を得る](#35-enum-bounded-で全部を得る)
  - [逆変換は `Maybe` を返す](#逆変換は-maybe-を返す)
- [3.6 型で分けた効果](#36-型で分けた効果)
- [3.7 この章のまとめ](#37-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 3.1 Before: 文字列で持ち回る

移植元の Python 版、そして移植当初の Haskell 版は、メトリック名を文字列で扱っていました。イメージとしてはこうです。

```haskell
-- Before（再現コード。実在しません）
syncMetric :: Text -> ...
syncMetric "sleep"     = ...
syncMetric "readiness" = ...
syncMetric other       = error ("unknown metric: " <> unpack other)

allMetrics :: [Text]
allMetrics = ["sleep", "readiness", "activity", "stress", "spo2", ...]
```

問題は 4 つあります。

1. **タイプミスがコンパイルを通る。** `"readiness"` を `"readyness"` と書いても型は合う。実行時に静かに何も同期されない。
2. **網羅性が保証されない。** メトリックを 1 つ追加したとき、`allMetrics` に足しても分岐に足し忘れる。コンパイラは何も言わない。
3. **無効な値が表現できてしまう。** `syncMetric "banana"` は型検査を通る。
4. **文字列の出どころが分散する。** DB のカラム値、Oura API のパス、JSON API のキーで同じ文字列を書くため、片方だけ変えると壊れる。

## 3.2 `data` 宣言の文法

### 直和（enum 型）

```haskell
-- src/Metric.hs:27
data DailyMetric
    = Sleep
    | Readiness
    | Activity
    | Stress
    | Spo2
    | Resilience
    | CardiovascularAge
    | Temperature
      -- ^ Derived from the readiness payload; never fetched on its own.
    | VO2Max
      -- ^ Reported by @get_sync_status@, but the sync never fetches it.
    deriving (Eq, Ord, Show, Enum, Bounded)
```

- `data 型名 = コンストラクタ | コンストラクタ | ...`
- `|` は「または」。この型の値は**列挙した 9 つのいずれか**であり、それ以外はありえません。
- 型名（`DailyMetric`）とコンストラクタ名（`Sleep`）は別の名前空間なので、同名にもできます（後述の `DateRange` がそれ）。

### 直和 + 直積（コンストラクタが引数を取る）

```haskell
-- src/Metric.hs:44
data Metric
    = Daily DailyMetric
    | HeartrateSeries
    deriving (Eq, Ord, Show)
```

`Daily` は `DailyMetric` を 1 つ取るコンストラクタです。**コンストラクタは関数として使えます**（`Daily :: DailyMetric -> Metric`）。

```haskell
-- src/Metric.hs:88
syncStatusMetrics = map Daily allDailyMetrics ++ [HeartrateSeries]
```

「日次メトリック 9 種、または心拍系列」という**選択肢の集合**が、この 4 行で定義されています。心拍は 1 日 1 行ではなくサンプル単位で、別テーブルに入り、取得も 30 日窓で行う——という性質の違いが、型として表現されています。

> コメントにあるとおり、`HeartrateSeries` という名前は persistent が生成するエンティティ型 `Heartrate` との衝突を避けるためです（`src/Metric.hs:43`）。**名前の衝突は設計の匂いではなく単なる現実**なので、こういう妥協は理由をコメントに残せば十分です。

### `deriving` — インスタンスの自動導出

```haskell
deriving (Eq, Ord, Show, Enum, Bounded)
```

| クラス | 導出されるもの | このプロジェクトでの用途 |
|---|---|---|
| `Eq` | `==`, `/=` | `metric == Daily Temperature` によるスキップ判定 |
| `Ord` | `<`, `compare` | `Map Metric Int` のキーにする（`Map` は `Ord` を要求） |
| `Show` | `show` | ログ・テストの失敗メッセージ |
| `Enum` | `succ`, `[a ..]` | `[minBound .. maxBound]` |
| `Bounded` | `minBound`, `maxBound` | 同上 |

`Ord` を導出すると、**コンストラクタを書いた順序**が大小になります。ここでは意味のある順序ではなく「`Map` のキーにできること」が目的なので、それで構いません。逆に、順序に意味を持たせたい型では宣言順が仕様になるため、コメントを残すべきです。

## 3.3 文字列表現は 1 箇所に置く

```haskell
-- src/Metric.hs:50
-- | The name used in the DB @metric@ column, the JSON API and the Oura API.
dailyMetricName :: DailyMetric -> Text
dailyMetricName = \case
    Sleep             -> "sleep"
    Readiness         -> "readiness"
    Activity          -> "activity"
    Stress            -> "stress"
    Spo2              -> "spo2"
    Resilience        -> "resilience"
    CardiovascularAge -> "cardiovascular_age"
    Temperature       -> "temperature"
    VO2Max            -> "vo2_max"
```

これで 3.1 の 4 つの問題がすべて消えます。

1. `Readyness` と書けばコンパイルエラー（スコープにない）。
2. 分岐の書き忘れは `-Wall` 下で警告になる（後述）。
3. `DailyMetric` 型の値は 9 つしか存在しない。無効な値を作れない。
4. 文字列は `dailyMetricName` にしかない。DB も API もここを見る。

### 文法メモ: `\case`（LambdaCase）

```haskell
dailyMetricName = \case
    Sleep -> "sleep"
```

は

```haskell
dailyMetricName m = case m of
    Sleep -> "sleep"
```

の略記です。**引数に名前を付ける必要がないときに使います。** ポイントフリースタイルと `case` を両立させるための構文で、実務コードでは非常によく出てきます。`{-# LANGUAGE LambdaCase #-}` が必要です。

「引数名を考えなくてよい」のは小さな利点に見えますが、`m`、`metric`、`dm` のような**情報のない名前**を書かずに済むのは読みやすさに効きます。

## 3.4 網羅性検査を「効かせる」

「コンパイラが分岐漏れを検出してくれる」は、正確には次の条件下でのみ成り立ちます。

- パターンマッチが `case` / 関数定義の形をしている
- `_ -> ...` のワイルドカードで捨てていない
- `-Wall`（正確には `-Wincomplete-patterns`）が有効

このプロジェクトは `package.yaml:61` で library に `-Wall` を付けています。だから次の関数群は、メトリックを追加した瞬間にコンパイラが「ここも考えろ」と指摘します。

```haskell
-- src/Sync.hs:60 — スコアがどのフィールドか
extractScore :: DailyMetric -> Value -> Maybe Value
extractScore metric record = case metric of
    Sleep       -> jsonLookup "score" record
    ...
    VO2Max      -> Nothing

-- src/Sync.hs:140 — どの API 関数で取るか
fetchFn :: OuraClient -> DailyMetric -> Maybe (DateRange -> IO [Value])
fetchFn client = \case
    Sleep             -> Just (getDailySleep client)
    ...
    Temperature       -> Nothing
    VO2Max            -> Nothing

-- src/Advice.hs:105 — LLM に渡すフィールドはどれか
extractKeyFields :: DailyMetric -> A.Value -> A.Value
extractKeyFields metric row = ... case metric of
    Sleep -> [("contributors", g "contributors")]
    ...
    VO2Max -> []
```

**ここが設計の勘所です。** `Temperature` と `VO2Max` は「取得しないメトリック」ですが、`fetchFn` はそれを `Maybe` で表しています。`_ -> Nothing` と書けば行数は減りますが、**新しいメトリックを足したときに黙って「取得しない」側に落ちる**ようになります。全ケースを列挙しておけば、追加時にコンパイラが漏れを教えてくれます。

> **実務ルール**: ADT に対する `case` でワイルドカード `_` を使うのは、「今後どんな値が増えても、この分岐でよい」と断言できるときだけ。

断言できる例もあります。

```haskell
-- src/Handler/Advice.hs:70
case jobStatus job of
    Completed -> returnJson $ A.object (base ++ ["advice" A..= jobAdvice job])
    Failed    -> sendStatusJSON status502 $ A.object (base ++ ["error" A..= ...])
    _         -> sendStatusJSON status202 (A.object base)
```

「完了・失敗以外はすべて『まだ処理中』として 202」という規則は、状態が増えても変わりません。**規則が値の増減に依存しないなら `_` でよい**、という判断です。

## 3.5 `Enum` / `Bounded` で「全部」を得る

```haskell
-- src/Metric.hs:71
allDailyMetrics :: [DailyMetric]
allDailyMetrics = [minBound .. maxBound]
```

`deriving (Enum, Bounded)` があるので、全コンストラクタのリストが自動的に得られます。手書きのリストと違い、**追加時に更新し忘れることが原理的にない**のが重要です。

そこから派生する部分集合も、リストを手書きせずに定義します。

```haskell
-- src/Metric.hs:76
dashboardMetrics :: [DailyMetric]
dashboardMetrics = filter (/= VO2Max) allDailyMetrics

-- src/Metric.hs:81
syncTargets :: [Metric]
syncTargets =
    map Daily (filter (`notElem` [Temperature, VO2Max]) allDailyMetrics)
        ++ [HeartrateSeries]
```

「全部から除外する」と書くと、新メトリック追加時の既定が**含む**になります。「含めるものを列挙する」と書くと既定が**含まない**になります。どちらが安全かは場合によりますが、**どちらを既定にするかを意識して選ぶ**べきです。ここではダッシュボードに新メトリックが自動的に載る方が望ましいので、除外方式を選んでいます。

### 逆変換は `Maybe` を返す

```haskell
-- src/Metric.hs:66
parseDailyMetric :: Text -> Maybe DailyMetric
parseDailyMetric name =
    lookup name [ (dailyMetricName m, m) | m <- allDailyMetrics ]
```

外から来る文字列（URL セグメント、クエリパラメータ、リクエストボディ）は信用できないので `Maybe` で受けます。ここでも変換表を手書きせず `allDailyMetrics` から生成しているため、**`dailyMetricName` と `parseDailyMetric` が食い違うことがありません**。往復の一貫性が構造的に保証されている、という点を味わってください。

## 3.6 型で分けた効果

`Metric` と `DailyMetric` を別の型にしたことで、次が言えるようになりました。

- 「日次メトリック」だけを受け取る関数は `DailyMetric` を取る（`extractScore`、`upsertDailyMetric`）。心拍を渡すことが**書けない**。
- 「同期対象」全体を扱う関数は `Metric` を取る（`findMissingRange`、`updateSyncLog`、`runSync`）。
- 両者の分岐が必要な箇所は `case` で明示される。

```haskell
-- src/Sync.hs:263
syncRange = \case
    HeartrateSeries -> syncHeartrateRange
    Daily daily     -> syncDailyRange daily
```

```haskell
-- src/Db.hs:189
cnt <- case metric of
    HeartrateSeries -> countRaw "SELECT COUNT(*) FROM heartrate" []
    Daily daily ->
        countRaw "SELECT COUNT(*) FROM daily_metrics WHERE metric = ?"
                 [toPersistValue (dailyMetricName daily)]
```

**型が違うということは、「別のテーブルを見る」「別の API を叩く」という事実がコンパイラに伝わっているということです。** 文字列で `if metric == "heartrate"` と書いていた頃は、この事実はプログラマの頭の中にしかありませんでした。

型化で防げるようになったことを整理します。

| 以前ありえた間違い | 今どうなるか |
|---|---|
| メトリック名のタイプミス | コンパイルエラー |
| 新メトリック追加時の分岐漏れ | `-Wall` 警告（`extractScore`, `fetchFn`, `extractKeyFields`） |
| 心拍を日次メトリック用の関数に渡す | コンパイルエラー |
| DB の値と API のパスで名前が食い違う | `dailyMetricName` 一元化で発生しない |

## 3.7 この章のまとめ

- 文字列で分岐しているコードを見たら、まず ADT にできないか考える。
- `data` の `|` は「または」。コンストラクタは関数でもある。
- `deriving` する型クラスには理由がある。`Ord` は `Map` のキーにするため、`Enum`/`Bounded` は「全部のリスト」を得るため。
- ADT にしたら `[minBound .. maxBound]` で全体を導出し、手書きのリストを消す。部分集合は「全体から除外」か「列挙」かを意識して選ぶ。
- ワイルドカード `_` は網羅性検査を無効化する。ADT に対しては原則使わない。使うのは「規則が値の増減に依存しない」と断言できるときだけ。
- 外部から来る文字列は `Maybe` を返す関数で受ける。変換表は正引きから生成して二重管理を避ける。
- 性質が違うものは別の型にする。型が違えば、扱いが違うことがコンパイラに伝わる。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `data T = A \| B` | 直和型（値は列挙したもののみ） | `DailyMetric` |
| `data T = C X \| D` | 引数を取るコンストラクタ | `Metric = Daily DailyMetric \| HeartrateSeries` |
| `deriving (Eq, Ord, Show)` | インスタンスの自動導出 | 両方の型 |
| `deriving (Enum, Bounded)` | `[minBound .. maxBound]` を可能にする | `allDailyMetrics` |
| `\case` | 引数名を書かない `case`（`LambdaCase`） | `dailyMetricName` |
| `-Wincomplete-patterns` | 分岐漏れの警告（`-Wall` に含まれる） | `package.yaml` |
| `[minBound .. maxBound]` | `Enum`+`Bounded` による全列挙 | `allDailyMetrics` |

---

← [第2章 関数・パターン・演算子](02-functions-and-patterns.md) | [目次](README.md) | [第4章 newtype とレコード](04-newtype-and-records.md) →
