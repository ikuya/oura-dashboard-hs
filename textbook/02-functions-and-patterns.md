# 第 2 章 関数・パターン・演算子

← [第1章 Haskell のソースを読む](01-reading-a-haskell-project.md) | [目次](README.md) | [第3章 代数的データ型と網羅性](03-adt-and-exhaustiveness.md) →

> **この章で復習する文法**: 複数等式による関数定義、パターンの種類（コンストラクタ・as パターン・ネスト）、ガードとパターンガード、`where` と `let`、部分適用、関数合成、`$` `.` `<$>` `<*>` `=<<` `<>` の読み方

Haskell の関数定義には、他の言語にない自由度があります。同じ処理を「複数の等式」「`case`」「ガード」「`where` に切り出す」のどれでも書けます。**どれを選ぶかで読みやすさが決まる**ので、実物での使い分けを見ていきます。

## 目次

- [2.1 関数定義の 3 つの形](#21-関数定義の-3-つの形)
  - [形 1: 複数の等式（パターンで分岐）](#形-1-複数の等式パターンで分岐)
  - [形 2: `case` 式](#形-2-case-式)
  - [形 3: ガード](#形-3-ガード)
- [2.2 パターンの種類](#22-パターンの種類)
  - [文法メモ: as パターン（`@`）](#文法メモ-as-パターン)
  - [文法メモ: パターンマッチの失敗が「捨てられる」場所](#文法メモ-パターンマッチの失敗が捨てられる場所)
- [2.3 ガードとパターンガード](#23-ガードとパターンガード)
  - [真偽値のガードを連ねる](#真偽値のガードを連ねる)
  - [文法メモ: パターンガード](#文法メモ-パターンガード)
- [2.4 `where` と `let`](#24-where-と-let)
- [2.5 部分適用と関数合成](#25-部分適用と関数合成)
  - [部分適用](#部分適用)
  - [関数合成 `.`](#関数合成)
- [2.6 演算子の道具箱](#26-演算子の道具箱)
  - [`$` — 括弧を減らす](#括弧を減らす)
  - [`.` — 関数合成](#関数合成-1)
  - [`<$>` — 関数を「包まれた値」に適用（`fmap`）](#関数を包まれた値に適用fmap)
  - [`<*>` — 複数の「包まれた値」を集める](#複数の包まれた値を集める)
  - [`=<<` と `>>=` — 「包まれた値」を次の計算に渡す](#と-包まれた値を次の計算に渡す)
  - [`<>` — 結合](#結合)
  - [優先順位の実務的な扱い](#優先順位の実務的な扱い)
- [2.7 この章のまとめ](#27-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 2.1 関数定義の 3 つの形

### 形 1: 複数の等式（パターンで分岐）

```haskell
-- src/Json.hs:23
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup k (Object o) = KM.lookup (K.fromText k) o
jsonLookup _ _          = Nothing
```

引数の形（パターン）ごとに等式を並べます。**上から順に照合され、最初にマッチしたものが使われます**。`_` はワイルドカードで「何にでもマッチするが、値は使わない」。

```haskell
-- src/Metric.hs:62
metricName :: Metric -> Text
metricName (Daily m) = dailyMetricName m
metricName HeartrateSeries = "heartrate"
```

`(Daily m)` は「`Daily` コンストラクタで作られた値なら、その中身を `m` と呼ぶ」という**コンストラクタパターン**です。分解と分岐が 1 つの記法で同時にできるのが Haskell のパターンマッチの本質です。

### 形 2: `case` 式

```haskell
-- src/Sync.hs:60
extractScore :: DailyMetric -> Value -> Maybe Value
extractScore metric record = case metric of
    Sleep       -> jsonLookup "score" record
    Readiness   -> jsonLookup "score" record
    ...
    VO2Max      -> Nothing
```

分岐の対象が引数そのものでない場合や、共通の引数（ここでは `record`）を何度も書きたくない場合に使います。**式なので、どこにでも書けます**（`let` の右辺、`do` の中、関数の引数）。

### 形 3: ガード

```haskell
-- src/Db.hs:108
getDailyMetricsBulk metrics (DateRange start end)
    | null metrics = return mempty
    | otherwise = do
        ...
```

`|` の右が `True` になった枝が選ばれます。`otherwise` は `True` の別名です（変数なので、実は何にでも束縛できますが、慣習として「その他」を意味します）。

**使い分けの目安**:

| 条件の性質 | 使うもの |
|---|---|
| 引数の**形**で分かれる | 複数等式 / `case` |
| 引数の**値の条件**で分かれる | ガード |
| 分岐対象が引数以外の式 | `case` |
| 引数に名前を付けたくない | `\case`（第 3 章） |

## 2.2 パターンの種類

このコードベースに実在するものだけを挙げます。

```haskell
-- ① コンストラクタパターン
metricName (Daily m) = dailyMetricName m

-- ② ネストしたパターン（Just の中の Object）
--    src/Sync.hs:67
Spo2 -> case jsonLookup "spo2_percentage" record of
    Just nested@(A.Object _) -> jsonLookup "average" nested
    other                    -> other

-- ③ タプルパターン
--    src/Db.hs:101
[ mergeRow day score (parseDataJson dj)
| (Single day, Single score, Single dj) <- rows ]

-- ④ リストパターン
--    src/DateText.hs:50
case T.splitOn "-" t of
    [y, m, d] | ... -> Just (DayText t)
    _ -> Nothing

-- ⑤ コンス（先頭:残り）パターン
--    src/Sync.hs:203
go total (range:rest) = do ...
```

### 文法メモ: as パターン（`@`）

```haskell
Just nested@(A.Object _) -> jsonLookup "average" nested
```

`nested@(A.Object _)` は「`A.Object _` にマッチさせつつ、マッチした値**全体**を `nested` と呼ぶ」という記法です。分解した部品と、元の値の両方が欲しいときに使います。

Oura API は `spo2_percentage` をオブジェクトで返すこともスカラーで返すこともあります。オブジェクトなら `average` を掘り、それ以外はそのまま返す、という仕様が、この 2 行に収まっています。

同じ記法が関数の引数でも使われています。

```haskell
-- src/Sync.hs:110
syncDailyMetric client metric range@(DateRange start end) = do
    records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
    ...
```

`range` 全体（クライアントに渡す）と、`start` / `end`（ログに出す）の両方が要るので、as パターンが最適です。これを使わないと `rangeStart range` と書き直すか、`DateRange start end` を再構築することになります。

### 文法メモ: パターンマッチの失敗が「捨てられる」場所

`do` 記法とリスト内包表記では、パターンマッチの失敗が**エラーではなく「その要素を捨てる」**として扱われます。

```haskell
-- src/Db.hs:67 — bpm が Nothing の行は自然に落ちる
let valid = [ (ts, bpm) | (ts, Just bpm) <- records, not (null ts) ]

-- src/Sync.hs:112 — day フィールドを持たないレコードは落ちる
let dated = [ (day, r) | r <- records, Just day <- [recordDay r] ]
```

2 つ目の `Just day <- [recordDay r]` は独特の書き方です。内包表記のジェネレータ（`<-`）の右辺はリストでなければならないので、`recordDay r :: Maybe DayText` を 1 要素のリストに包んでいます。**「`Nothing` なら候補が空になる＝この行は生成されない」**という仕掛けです。

命令型言語なら `if x is None: continue` と書くところが、パターンで表現されています。

## 2.3 ガードとパターンガード

ガードの `|` の右は、正確には**カンマで連ねた条件の列**です。それぞれの条件には次の 3 つの形が書けます（Haskell 2010 のガードの定義。3 つ目がパターンガードです）。

| 形 | 意味 |
|---|---|
| 真偽値の式 | `True` なら次の条件へ進む |
| `let x = e` | 以降の条件と右辺で使える束縛 |
| `pat <- expr`（**パターンガード**） | `expr` を評価し、パターンにマッチしたら束縛して次へ。しなければこの枝を捨てる |

列の条件がすべて成立したときだけ、その枝の右辺が選ばれます。このコードベースで使われているのは 1 番目の形（真偽値をカンマで連ねる）だけです。まず実例を見てから、パターンガードの文法を書き換え例で確認します。

### 真偽値のガードを連ねる

```haskell
-- src/DateText.hs:49
parseDayText :: Text -> Maybe DayText
parseDayText t = case T.splitOn "-" t of
    [y, m, d] | T.length y == 4 && T.length m == 2 && T.length d == 2
              , all (T.all isDigit) [y, m, d] -> Just (DayText t)
    _ -> Nothing
```

読み方はこうです。

1. まず**パターン**: `T.splitOn "-" t` の結果が要素 3 個のリスト `[y, m, d]` である
2. 次に**ガード**: それぞれの長さが 4, 2, 2 である
3. **かつ**（`,` は AND）すべて数字だけからなる

`case` の枝にガードを付けると、このように「形（パターン）」と「値の条件（ガード）」を 1 つの枝にまとめられます。この 3 条件が「`YYYY-MM-DD` の形をしている」の定義になっています。なお、ここで `|` の右に並んでいるのはどちらもただの真偽値の式であって、パターンガードではありません。

パターンと述語の組み合わせは `collectGaps` にもあります。

```haskell
-- src/Sync.hs:179
collectGaps :: (DayText -> Bool) -> [DayText] -> [DateRange]
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
  where
    gapRange grp = case grp of
        (d:_) | isMissing d -> DateRange d <$> lastMay grp
        _                   -> Nothing
```

`(d:_) | isMissing d` は「グループが空でなく、**かつ**その先頭が欠損日である場合」。パターン（形）と述語（値の条件）を 1 行で組み合わせています。

`runSync` の内部にはガードによる早期スキップもあります。

```haskell
-- src/Sync.hs:240
step end acc metric
    | metric == Daily Temperature = return acc  -- derived from readiness
    | otherwise = do
        ...
```

温度は readiness から派生生成されるので、同期対象から外す——という**仕様上の例外**が、ガード 1 行とコメントで表現されています。

### 文法メモ: パターンガード

`|` の右には `pat <- expr` という形も書けます。`expr` を評価してパターンにマッチしたら変数を束縛して次の条件へ進み、マッチしなければ**その枝ごと捨てて**次のガード・次の等式に落ちます。「`Maybe` を返す関数を呼び、`Just` のときだけこの枝を選ぶ」が典型的な使い方です。

このコードベースには実例がないため、2.2 節で見た `extractScore` の `Spo2` の分岐（`case` + as パターン）をパターンガードで書き換えた例を示します（**リポジトリのコードではありません**）。

```haskell
-- 書き換え例。実物は Sync.hs の case 式（2.2 節）
spo2Score :: Value -> Maybe Value
spo2Score record
    | Just nested@(A.Object _) <- jsonLookup "spo2_percentage" record
        = jsonLookup "average" nested
    | otherwise = jsonLookup "spo2_percentage" record
```

1 本目のガードは「`spo2_percentage` キーがあり、**かつ**その値がオブジェクトである」ときだけ成立します。マッチしなければ（キーが無い、または値がスカラー）`otherwise` に落ちます。実物が `case` で書かれているのは、マッチしなかったときに検索結果（`other`）をそのまま返せて、同じ `jsonLookup` を 2 回書かずに済むからです。**どちらでも書ける場面では、同じ式を二度評価しない方・分岐全体が 1 箇所に見える方を選ぶ**、というのが実務の判断です。

## 2.4 `where` と `let`

どちらもローカル束縛ですが、性質が違います。

| | スコープ | 書ける場所 |
|---|---|---|
| `where` | その**関数定義全体**（すべてのガード・等式から見える） | 関数定義の末尾 |
| `let` | その**式の中**だけ | 式ならどこでも（`do` 内、内包表記内も） |

```haskell
-- src/Advice.hs:105 — let（式の中だけで使う）
extractKeyFields :: DailyMetric -> A.Value -> A.Value
extractKeyFields metric row =
    let g k = fromMaybe A.Null (jsonLookup k row)
        base = [("day", g "day"), ("score", g "score")]
        extra = case metric of
            Sleep     -> [("contributors", g "contributors")]
            Readiness -> [("contributors", g "contributors")]
            Activity  -> [("active_calories", g "active_calories"), ("steps", g "steps")]
            ...
    in A.Object (KM.fromList (base ++ extra))
```

`g k = fromMaybe A.Null (jsonLookup k row)` は「無ければ `null`」を短く書くためのローカル関数です。同じパターンが 10 回以上出るので、1 文字の名前が正当化されます。**モジュール全体に公開するほどではない補助関数は `let` / `where` に置く**、という判断です。

```haskell
-- src/Sync.hs:110 — where（複数のガード／等式から見える）
syncDailyMetric client metric range@(DateRange start end) = do
    ...
  where
    writeTemperature day r =
        upsertDailyMetric Temperature day
            (jsonDouble =<< jsonLookup "temperature_deviation" r)
            (A.Object $ KM.fromList
                [ ("day", A.toJSON day)
                , ("temperature_deviation", field "temperature_deviation")
                , ...
                ])
      where
        field k = fromMaybe A.Null (jsonLookup k r)
```

**`where` は入れ子にできます。** `field` は `writeTemperature` の中でだけ意味を持つ（引数 `r` を捕まえている）ので、内側の `where` に置かれています。スコープを最小にするというだけの理由ですが、読み手は「`field` は外では使われない」と即座に判断できます。

`Oura.realClient` は `where` を大きく使った例です。

```haskell
-- src/Oura.hs:60
realClient :: AppLog -> Text -> OuraClient
realClient appLog token = OuraClient
    { getDailySleep = getDated "/v2/usercollection/daily_sleep"
    , ...
    }
  where
    getDated path range = getPaged path [ ... ]

    getPaged :: Text -> [(Text, Text)] -> IO [Value]
    getPaged path params = go Nothing []
      where
        go mnext acc = do ...

    httpGet :: Text -> [(Text, Text)] -> IO Value
    httpGet path params = do ...

    mkHttpError :: Int -> OuraError
    mkHttpError status = ...
```

HTTP クライアントの実装（3 つの関数）が丸ごと `where` に隠れています。**モジュールの export リストにも載らず、同じモジュールの他の関数からも見えません。** しかも `appLog` と `token` を引数から捕まえている（クロージャ）ので、`getPaged` に毎回渡す必要がありません。第 10 章で扱う依存性注入の土台です。

> **`where` に型シグネチャを書く。** 上の `getPaged :: Text -> [(Text, Text)] -> IO [Value]` のように、`where` 内の関数にも型を書けます（`ScopedTypeVariables` があれば外側の型変数も使えます）。ローカル関数でも、引数が 2 つ以上あるなら書く価値があります。

## 2.5 部分適用と関数合成

### 部分適用

第 1 章で見たとおり、複数引数の関数は「1 引数関数の連なり」です。だから途中まで適用できます。

```haskell
-- src/Oura.hs:62
{ getDailySleep     = getDated "/v2/usercollection/daily_sleep"
, getDailyReadiness = getDated "/v2/usercollection/daily_readiness"
```

`getDated :: Text -> DateRange -> IO [Value]` に第 1 引数だけ与えた結果は `DateRange -> IO [Value]` という**関数**です。`OuraClient` の 9 フィールドのうち 8 つ（`getDailySleep` 〜 `getVO2Max`）は、この `getDated` にパスだけ変えて束ねられています。継承もテンプレートメソッドも使っていません。

残る 1 つ、`getHeartrate` だけは別実装です。`getDated` が組み立てる `start_date`/`end_date` パラメータではなく、`start_datetime`/`end_datetime`（`dateToDatetime` で変換）を使って `getPaged` を直接呼んでいます。心拍数だけ Oura API のエンドポイントがタイムスタンプ単位のクエリを要求するためで、9 フィールド全部が同じ関数の部分適用というわけではありません。

```haskell
-- src/Metric.hs:83 — Daily を map に部分適用
map Daily (filter (`notElem` [Temperature, VO2Max]) allDailyMetrics)
```

`Daily` はデータコンストラクタですが、これも関数（`DailyMetric -> Metric`）なので `map` に渡せます。

### 関数合成 `.`

```haskell
-- src/DateText.hs:63
formatDay :: Day -> DayText
formatDay = DayText . pack . formatTime defaultTimeLocale dayFormat
```

`(f . g) x = f (g x)`。右から左に流れます。上の定義は「`Day` を書式化して `String` にし、`pack` で `Text` にし、`DayText` で包む」。引数 `d` を書いていないことに注目してください（ポイントフリースタイル）。

```haskell
-- src/DateText.hs:67
addDaysT :: Integer -> DayText -> DayText
addDaysT n = formatDay . addDays n . parseDay
```

「`DayText` を `Day` にし、`n` 日ずらし、`DayText` に戻す」。`n` は書くが `DayText` は書かない、という部分的なポイントフリーです。**変換の連鎖はポイントフリーで書くと処理の流れがそのまま見えます。**

ただしやりすぎると暗号になります。目安は「合成が 2〜3 段まで、途中で `flip` や `uncurry` をこねる必要がない」なら省略してよい、それを超えたら引数を書く、です。

## 2.6 演算子の道具箱

実務コードで頻出する 6 つを、実物で確認します。

### `$` — 括弧を減らす

```haskell
-- src/Db.hs:91
return $ unSingle <$> headMay rows
-- return (unSingle <$> headMay rows) と同じ
```

`f $ x = f x` ですが、優先順位が最低かつ右結合なので、「ここから右を全部ひとかたまりにする」という意味になります。

### `.` — 関数合成

```haskell
-- src/Handler/Api.hs:40
stored <- appPassword . appSettings <$> getYesod
```

「`App` から設定を取り、そこからパスワードを取る」を合成しています。レコードのフィールドアクセサは関数なので、そのまま合成できます。

### `<$>` — 関数を「包まれた値」に適用（`fmap`）

```haskell
-- src/Foundation.hs:175
isAuthenticated :: Handler Bool
isAuthenticated = isJust <$> lookupSession sessionAuthKey
```

`lookupSession` は `Handler (Maybe Text)` を返します。その中身に `isJust` を適用して `Handler Bool` にしています。`do` で書くとこうなります。

```haskell
isAuthenticated = do
    ms <- lookupSession sessionAuthKey
    return (isJust ms)
```

**1 行で済む変換は `<$>` を使う**のが慣習です。`do` を 3 行書くほどのことではありません。

### `<*>` — 複数の「包まれた値」を集める

```haskell
-- src/Advice.hs:207
periodBounds v = (,) <$> field "start" <*> field "end"
  where
    field k = DayText <$> (jsonText =<< jsonLookup k v)
```

`(,)` はタプルを作る関数（`a -> b -> (a, b)`）です。`field "start"` と `field "end"` が両方 `Just` ならペアにし、片方でも `Nothing` なら全体が `Nothing` になります。

**`<$>` と `<*>` の並び（Applicative スタイル）は、「独立した複数の失敗しうる値を集めて 1 つにする」定型**です。後の計算が前の結果に依存するなら `do`、依存しないなら `<$>`/`<*>`、と使い分けます。

### `=<<` と `>>=` — 「包まれた値」を次の計算に渡す

```haskell
-- src/Sync.hs:78
recordDay r = DayText <$> (jsonText =<< jsonLookup "day" r)
```

`jsonText =<< jsonLookup "day" r` は `jsonLookup "day" r >>= jsonText` と同じです。「キーを引いて、それが文字列なら取り出す。どちらかが失敗したら `Nothing`」。

左向き（`=<<`）で書くと **`.` による関数合成と目線の向きが揃う**（右から左）ので、`f =<< g =<< h x` のような連鎖が読みやすくなります。このコードベースは一貫して `=<<` を使っています。

### `<>` — 結合

```haskell
-- src/Sync.hs:119
$logInfo ("sync " <> dailyMetricName metric
    <> " " <> unDayText start <> ".." <> unDayText end
    <> ": " <> tshow count <> " rows")
```

`Semigroup` の演算子で、`Text` なら連結、リストなら `++`、`Map` なら和になります。**文字列連結は `++` ではなく `<>`** と覚えてよいでしょう（`++` はリスト専用）。

`tshow :: Show a => a -> Text` は ClassyPrelude が提供する「`show` の `Text` 版」です。標準の `show` は `String` を返すので、`Text` の連鎖に混ぜるにはこれが要ります。

### 優先順位の実務的な扱い

```haskell
-- src/Oura.hs:99
let req = setRequestHeader "Authorization" ["Bearer " <> encodeUtf8 token]
        $ setRequestQueryString [ ... ]
        $ setRequestResponseTimeout (responseTimeoutMicro apiTimeoutMicros)
        $ req0
```

`$` を行頭に置いて連ねるこの形は、「`req0` に対して下から順に設定を適用する」と読みます。関数合成 `.` で書いても同じですが、**最後の値（`req0`）を明示できる**ので設定の連鎖ではこちらが好まれます。

演算子の優先順位を全部覚える必要はありません。**迷ったら括弧を書く**。ただし `$`（最低・右結合）、`.`（高い・右結合）、`<$>` と `<*>`（左結合、同じ優先順位）の 4 つだけは体に入れておくと、大半のコードが括弧なしで読めます。

## 2.7 この章のまとめ

- 分岐は「形なら複数等式／`case`」「値の条件ならガード」で選ぶ。
- as パターン（`x@(C y)`）は「全体と部品の両方が欲しい」ときに使う。
- 内包表記と `do` では、パターンマッチの失敗が「その要素を捨てる」になる。`Just x <- [m]` はその応用。
- ガードは `,` で条件を連ねられる（AND）。`pat <- expr`（パターンガード）も書けるが、このコードベースでは未使用。
- `where` は関数全体、`let` は式の中。補助関数はスコープを最小にする。`where` は入れ子にできる。
- 引数を部分適用して関数を作る。共通実装＋パラメータの表現手段になる。
- 変換の連鎖はポイントフリー（`.`）で書くと流れが見える。2〜3 段まで。
- `$` `.` `<$>` `<*>` `=<<` `<>` の 6 つを読めれば、実務コードの大半は括弧なしで読める。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `f (C x) = ...` | コンストラクタパターン | `metricName (Daily m)` |
| `x@(C y)` | as パターン | `range@(DateRange start end)` |
| `f x \| cond = ...` | ガード | `\| metric == Daily Temperature` |
| `\| c1, c2 -> ...` | ガードの連結（`,` は AND） | `parseDayText` |
| `\| pat <- e` | パターンガード（本コードベースでは未使用） | 2.3 の書き換え例 `spo2Score` |
| `[ e \| p <- xs, cond ]` | リスト内包表記（失敗は要素を捨てる） | `[ (ts, bpm) \| (ts, Just bpm) <- records ]` |
| `where` / `let ... in` | ローカル束縛（関数全体／式の中） | `realClient`, `extractKeyFields` |
| `f a` の部分適用 | 引数を一部だけ与える | `getDated "/v2/..."` |
| `f . g` | 関数合成（右から左） | `formatDay . addDays n . parseDay` |
| `f $ x` | 括弧の代わり（最低優先度・右結合） | `return $ ...` |
| `f <$> m` | `fmap`。包まれた値に関数を適用 | `isJust <$> lookupSession ...` |
| `f <$> a <*> b` | 複数の包まれた値を集める | `(,) <$> field "start" <*> field "end"` |
| `f =<< m` / `m >>= f` | 包まれた値を次の計算へ | `jsonText =<< jsonLookup "day" r` |
| `a <> b` | `Semigroup` の結合 | ログ文字列の連結 |

---

← [第1章 Haskell のソースを読む](01-reading-a-haskell-project.md) | [目次](README.md) | [第3章 代数的データ型と網羅性](03-adt-and-exhaustiveness.md) →
