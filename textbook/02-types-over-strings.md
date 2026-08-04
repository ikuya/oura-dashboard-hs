# 第 2 章 文字列を型にする — newtype と ADT

Haskell を実務で使う最大の見返りは「型でバグを防ぐ」ことです。ただし、型を使えば自動的にそうなるわけではありません。`Text` と `Text` を取り違えるバグは、型があっても止められません。

この章では、このプロジェクトが実際に行った **stringly-typed（何でも文字列）からの脱却**を追いかけます。コミット `1835052` "Replace stringly-typed metrics, dates and the global logger with types" が題材です。

## 2.1 Before: 文字列で持ち回る

移植元の Python 版、そして移植当初の Haskell 版は、メトリック名を文字列で扱っていました。イメージとしてはこうです。

```haskell
-- Before（実在しない再現コード）
syncMetric :: Text -> ...
syncMetric "sleep"     = ...
syncMetric "readiness" = ...
syncMetric "activity"  = ...
syncMetric other       = error ("unknown metric: " <> unpack other)

allMetrics :: [Text]
allMetrics = ["sleep", "readiness", "activity", "stress", "spo2", ...]
```

この設計の問題は 4 つあります。

1. **タイプミスがコンパイルを通る。** `"readiness"` を `"readyness"` と書いても型は合う。実行時に静かに何も同期されない。
2. **網羅性が保証されない。** メトリックを 1 つ追加したとき、`allMetrics` に足しても `syncMetric` の分岐に足し忘れる。コンパイラは何も言わない。
3. **無効な値が表現できてしまう。** `syncMetric "banana"` は型検査を通る。
4. **文字列の出どころが分散する。** DB のカラム値、Oura API のパス、JSON API のキーで同じ文字列を書くため、片方だけ変えると壊れる。

## 2.2 After: 列挙型にする

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

そして文字列表現は **1 箇所だけ**に置きます。

```haskell
-- src/Metric.hs:50
-- | The name used in the DB @metric@ column, the JSON API and the Oura API.
dailyMetricName :: DailyMetric -> Text
dailyMetricName = \case
    Sleep             -> "sleep"
    Readiness         -> "readiness"
    ...
    VO2Max            -> "vo2_max"
```

これで先の 4 問題がすべて消えます。

1. `Readyness` と書けばコンパイルエラー（スコープにない）。
2. 分岐の書き忘れは `-Wall` 下で「非網羅パターン」警告になる（後述）。
3. `DailyMetric` 型の値は 9 つしか存在しない。無効な値を作れない。
4. 文字列は `dailyMetricName` にしかない。DB もAPIもここを見る。

### `\case` の意味

`\case` は `LambdaCase` 拡張で、

```haskell
dailyMetricName = \case
    Sleep -> "sleep"
```

は

```haskell
dailyMetricName m = case m of
    Sleep -> "sleep"
```

の略記です。引数に名前を付ける必要がないときに使います。ポイントスタイル（引数を書かない）と `case` を両立させるための構文で、実務コードでは非常によく出てきます。

## 2.3 網羅性検査を「効かせる」

「コンパイラが分岐漏れを検出してくれる」というのは、正確には次の条件下でのみ成り立ちます。

- パターンマッチが `case` / 関数定義の形をしている
- `_ -> ...` のワイルドカードで捨てていない
- `-Wall`（正確には `-Wincomplete-patterns`）が有効

このプロジェクトは `package.yaml:61` で library に `-Wall` を付けています。だから次のような関数を書くと、メトリックを追加した瞬間にコンパイルが警告を出します。

```haskell
-- src/Sync.hs:60
extractScore :: DailyMetric -> Value -> Maybe Value
extractScore metric record = case metric of
    Sleep       -> jsonLookup "score" record
    ...
    VO2Max            -> Nothing
```

```haskell
-- src/Sync.hs:140
fetchFn :: OuraClient -> DailyMetric -> Maybe (DateRange -> IO [Value])
fetchFn client = \case
    Sleep             -> Just (getDailySleep client)
    ...
    Temperature       -> Nothing
    VO2Max            -> Nothing
```

**ここが設計の勘所です。** `Temperature` と `VO2Max` は「取得しないメトリック」ですが、`fetchFn` はそれを `Maybe` で表しています。`_ -> Nothing` と書けば行数は減りますが、**新しいメトリックを足したときに黙って「取得しない」側に落ちる**ようになります。全ケースを列挙しておけば、追加時にコンパイラが「ここも考えろ」と言ってくれます。

> 実務ルール: ADT に対する `case` でワイルドカード `_` を使うのは、「今後どんな値が増えても、この分岐でよい」と断言できるときだけ。

### `Enum` と `Bounded` で「全部」を得る

```haskell
-- src/Metric.hs:71
allDailyMetrics :: [DailyMetric]
allDailyMetrics = [minBound .. maxBound]
```

`deriving (Enum, Bounded)` があるので、全コンストラクタのリストが自動で得られます。手書きのリストと違い、**追加時に更新し忘れることが原理的にない**のが重要です。

そこから派生する部分集合も、リストを手で書かずに定義します。

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

「全部から除外する」と書くと、新メトリック追加時の既定が「含む」になります。「含めるものを列挙する」と書くと既定が「含まない」になります。どちらが安全かは場合によりますが、**どちらを既定にするかを意識して選ぶ**べきです。ここでは、ダッシュボードに新メトリックが自動的に載る方を選んでいます。

### 逆変換は `Maybe` を返す

```haskell
-- src/Metric.hs:66
parseDailyMetric :: Text -> Maybe DailyMetric
parseDailyMetric name =
    lookup name [ (dailyMetricName m, m) | m <- allDailyMetrics ]
```

外から来る文字列（URL セグメント、クエリパラメータ、リクエストボディ）は信用できないので、`Maybe` で受けます。ここでも変換表を手書きせず `allDailyMetrics` から作っているため、**`dailyMetricName` と `parseDailyMetric` が食い違うことがありません**。往復の一貫性が構造的に保証されている、という点を味わってください。

## 2.4 「種類が違うもの」を型で分ける

心拍データは他のメトリックと性質が違います。1 日 1 行ではなくサンプル単位で、別テーブルに入り、取得も 30 日窓で行います。移植元ではこの区別を「文字列が `"heartrate"` かどうか」で毎回判定していました。

型ではこう表します。

```haskell
-- src/Metric.hs:44
data Metric
    = Daily DailyMetric
    | HeartrateSeries
    deriving (Eq, Ord, Show)
```

この 1 つの型定義で、次のことが言えるようになります。

- 「日次メトリック」だけを受け取る関数は `DailyMetric` を引数に取る（`extractScore`、`upsertDailyMetric`）。心拍を渡すことが**書けない**。
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

コメントにあるとおり、`HeartrateSeries` という名前は persistent が生成するエンティティ型 `Heartrate` との衝突を避けるためです（`src/Metric.hs:41`）。**名前の衝突は設計の匂いではなく、単なる現実**なので、こういう実務的な妥協はコメントで理由を残しておけば十分です。

## 2.5 newtype で「同じ Text」を区別する

日付も同様に文字列でした。`YYYY-MM-DD` 形式の `Text` です。

```haskell
-- src/DateText.hs:33
newtype DayText = DayText { unDayText :: Text }
    deriving stock   (Show)
    deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)
```

`newtype` は「実行時のコストゼロで別の型を作る」機能です。コンパイル後は `Text` そのものになりますが、型検査の上では別物として扱われます。これで、

```haskell
-- 型エラーになる（DayText が要求される箇所に生の Text を渡した）
findMissingRange "2024-01-31" (Daily Sleep) someRandomText
```

のような取り違えが止まります。

### `deriving stock` / `deriving newtype` の意味

`DerivingStrategies` 拡張で、インスタンスの導出方法を明示できます。

| 戦略 | 意味 |
|---|---|
| `stock` | GHC 組み込みの導出（`Show`、`Eq`、`Ord`、`Enum` など） |
| `newtype` | 中身の型のインスタンスをそのまま流用（`GeneralizedNewtypeDeriving`） |
| `anyclass` | 型クラスの既定実装をそのまま使う |

ここでの選択は意図的です。

- `Show` は **stock**。`DayText {unDayText = "2024-01-01"}` と表示され、デバッグ時やテストの失敗メッセージで newtype であることが分かる（`newtype` 戦略にすると `"2024-01-01"` としか出ず、生の `Text` と区別がつかない）。
- `Eq`、`Ord`、`ToJSON`、`PersistField` は **newtype**。`Text` としての振る舞いをそのまま使いたい。JSON に出るときは `"2024-01-01"` という裸の文字列であってほしい（`Show` の表示とは別物）。

戦略を書かないと GHC がどちらかを選び、`ToJSON` の出力が `{"unDayText": "..."}` のようになったりします。**newtype に何を導出させるかは、外部との契約（JSON の形、DB の値）に直結する**ので、明示する価値があります。

### `Ord` に意味を持たせる

```haskell
-- src/DateText.hs:29
-- | A calendar day as the @YYYY-MM-DD@ string the DB and both APIs speak.
--
-- 'Ord' is the underlying text order, which for this format is chronological —
-- the sync layer compares and takes @min@/@max@ of days throughout.
```

これは巧妙な設計判断です。`YYYY-MM-DD` は**辞書順＝日付順**になる形式なので、`Text` の `Ord` をそのまま流用すれば日付比較になります。おかげで同期ロジックが `Day` への変換なしで書けます。

```haskell
-- src/Sync.hs:93 付近
let end = min requestedEnd today
...
    fetchStart = min refetchStart nextDay
in return $ if fetchStart > end then Nothing else Just (DateRange fetchStart end)
```

**この判断はコメントで根拠を残すべき類のものです。** 形式が変われば（例: `2024/1/5`）静かに壊れるからです。実際にコード中で明記されています。

### レコードで「順序の取り違え」を防ぐ

```haskell
-- src/DateText.hs:39
-- | An inclusive day range. Every fetch window and backfill gap is one; as a
-- record rather than a pair, the ends cannot be swapped by accident.
data DateRange = DateRange
    { rangeStart :: DayText
    , rangeEnd   :: DayText
    } deriving (Eq, Show)
```

`(DayText, DayText)` というタプルでも動きますが、`fetch (end, start)` と書いても型が合ってしまいます。名前付きレコードにすると、少なくとも**フィールドアクセス時に**取り違えが目に見えます。

さらに、`DateRange` が独立した型であることで、こういう定義が書けます。

```haskell
-- src/Oura.hs:41
data OuraClient = OuraClient
    { getDailySleep     :: DateRange -> IO [Value]
    , getDailyReadiness :: DateRange -> IO [Value]
    ...
```

引数 2 つのタプルだったら、この型は `(DayText, DayText) -> IO [Value]` になり、読み手に意味が伝わりません。

## 2.6 型化の効果を測る

型を入れた後のコードを見ると、**書ける間違いが減っている**ことが分かります。

| 以前ありえた間違い | 今どうなるか |
|---|---|
| メトリック名のタイプミス | コンパイルエラー |
| 新メトリック追加時の分岐漏れ | `-Wall` 警告（`extractScore`, `fetchFn`, `extractKeyFields`） |
| 心拍を日次メトリック用の関数に渡す | コンパイルエラー |
| 日付と他の `Text` の取り違え | コンパイルエラー |
| `DateRange` の start / end 取り違え | フィールド名で目視可能 |
| DB の値と API のパスで名前が食い違う | `dailyMetricName` 一元化で発生しない |

一方で**型化で防げていない**ものも正直に見ておきます。

- `DayText` はコンストラクタが公開されているので、`DayText "banana"` と書ける。形式の保証は型ではなく `parseDayText` の呼び出し規律に依存している（第 4 章、第 13 章演習 1）。
- `DateRange` は `start <= end` を保証しない。空範囲や逆転範囲を作れる。

「どこまで型で守り、どこから規律に頼るか」は常にトレードオフです。全部を型で縛ると（例えば `DayText` を smart constructor 限定にすると）、テストコードで `"2024-01-31"` とリテラルを書けなくなり、記述量が跳ね上がります。実際このプロジェクトは `IsString` を導出することで**テストの読みやすさを優先**しました。

```haskell
-- test/SyncSpec.hs:75 — IsString のおかげでリテラルがそのまま DayText になる
r <- runMem $ findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
r `shouldBe` Just (DateRange defaultStart "2024-01-31")
```

この判断自体は妥当です。問題は「外部入力にも同じ緩さが適用されてしまった」ことで、それが演習 1 の題材になります。

## 2.7 この章のまとめ

- 文字列で分岐しているコードを見たら、まず ADT にできないか考える。
- ADT にしたら `Enum`/`Bounded` で「全部のリスト」を導出し、手書きのリストを消す。
- ワイルドカード `_` は網羅性検査を無効化する。ADT に対しては原則使わない。
- 同じ `Text` でも意味が違うものは `newtype` で分ける。`deriving stock` / `deriving newtype` を明示する。
- 2 つ以上の同型の値を渡す関数は、タプルよりレコード。
- 型で守れない部分は、どこで守っているかをコメントに書く。

## 演習

1. `Metric.hs` に新しいメトリック `Workout` を追加してみてください（`dailyMetricName` は `"workout"`）。`stack build` を実行し、コンパイラが何箇所で「ここも直せ」と指摘するか数えてください。指摘された各箇所が、なぜ人間の判断を必要とするのか説明してください。
2. `dashboardMetrics` は `filter (/= VO2Max) allDailyMetrics` です。もし「ダッシュボードに出すものを列挙する」設計にすると、演習 1 の結果はどう変わりますか。どちらが好ましいか、このアプリの性質から論じてください。
3. `DayText` から `IsString` の導出を外すと、どのファイルが壊れますか（`grep` で予想 → 実際に外して確認）。テストコードの記述量はどう変わりますか。
