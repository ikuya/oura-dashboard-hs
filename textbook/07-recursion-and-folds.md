# 第 7 章 再帰・畳み込み・データ変換

命令型言語から来た人が Haskell で最初に戸惑うのは「ループが書けない」ことです。実際には、ループに相当する道具が用途別に分かれているだけです。この章では、このプロジェクトが使っている 5 つの形を、選択理由とともに見ます。

## 7.1 まず内包表記とライブラリ関数を試す

ループを書く前に、既存の関数で済まないかを考えます。

```haskell
-- src/Sync.hs:112
let dated = [ (day, r) | r <- records, Just day <- [recordDay r] ]
```

「レコードのうち `day` フィールドを持つものだけを、`(日付, レコード)` のペアにする」。フィルタと変換を同時にやっています。

`Just day <- [recordDay r]` という書き方に注目してください。リスト内包表記のジェネレータは**パターンマッチが失敗した要素を捨てる**性質があるので、`recordDay r` が `Nothing` の行は自然に落ちます。1 要素のリストに包んでいるのは、ジェネレータがリストを要求するためです。

同じことは `mapMaybe` でも書けます。

```haskell
mapMaybe (\r -> (,) <$> recordDay r <*> Just r) records
```

どちらが読みやすいかは好みですが、**「フィルタしながら変換する」ことを一目で伝える**という点で内包表記が選ばれています。

他にも:

```haskell
-- src/Db.hs:100 — SQL の結果行を JSON に変換
return [ mergeRow day score (parseDataJson dj)
       | (Single day, Single score, Single dj) <- rows ]

-- src/Metric.hs:68 — 変換表を生成
lookup name [ (dailyMetricName m, m) | m <- allDailyMetrics ]

-- src/Db.hs:67 — 不正なレコードを除外
let valid = [ (ts, bpm) | (ts, Just bpm) <- records, not (null ts) ]
```

`Db.hs:67` は「`bpm` が `Just` で、かつ `timestamp` が空でないものだけ」を、パターンマッチとガードの併用で表現しています。命令型なら `if` の入れ子か `continue` になるところです。

## 7.2 `foldM` — 状態を持ちながら順に処理する

メトリックごとに同期して結果を集める処理です。

```haskell
-- src/Sync.hs:231
result <- foldM (step end) (SyncResult M.empty M.empty) targets
```

```haskell
-- src/Sync.hs:240
step end acc metric
    | metric == Daily Temperature = return acc  -- derived from readiness
    | otherwise = do
        ranges <- rangesFor end metric
        (rows, merr) <- foldRanges (syncRange metric) ranges
        return SyncResult
            { syncedCounts = M.insert metric rows (syncedCounts acc)
            , syncErrors   = maybe id (M.insert metric) merr (syncErrors acc)
            }
```

`foldM :: Monad m => (a -> b -> m a) -> a -> [b] -> m a` は、**効果を伴う畳み込み**です。命令型で書けば

```python
result = SyncResult({}, {})
for metric in targets:
    result = step(result, metric)   # DB アクセスや HTTP を含む
```

に相当します。違いは、`result` が再代入される変数ではなく、各ステップの戻り値である点だけです。

### `maybe id (M.insert metric) merr` を読む

```haskell
syncErrors = maybe id (M.insert metric) merr (syncErrors acc)
```

初見では読みにくい式です。分解します。

- `maybe :: b -> (a -> b) -> Maybe a -> b`
- ここでの `b` は `Map Metric Text -> Map Metric Text`（**関数**）
- `merr` が `Nothing` なら `id`（何もしない関数）
- `merr` が `Just err` なら `M.insert metric err`（挿入する関数）
- 最後にその関数を `(syncErrors acc)` に適用

つまり **「エラーがあれば挿入、なければそのまま」** です。`case` で書くとこうなります。

```haskell
syncErrors = case merr of
    Nothing  -> syncErrors acc
    Just err -> M.insert metric err (syncErrors acc)
```

どちらが良いか。`maybe id f` は Haskell では慣用句で、慣れれば 1 行で読めます。ただし**慣用句を知らない読み手には不親切**でもあります。チームの習熟度で決めるべき類の判断です。この教材の立場としては、「読めるようになっておく」ことを推奨します。同じ形は非常に頻出します。

### `ClassyPrelude` の `foldM` を避けている理由

```haskell
-- src/Sync.hs:26
import ClassyPrelude hiding (foldM)
...
import Control.Monad (foldM)
```

ClassyPrelude の `foldM` は `MonoFoldable` ベースで、型はこうです。

```
foldM :: (MonoFoldable mono, Monad m) => (a -> Element mono -> m a) -> a -> mono -> m a
```

`Control.Monad` 版（`Foldable t => (b -> a -> m b) -> b -> t a -> m b`）と使い勝手はほぼ同じですが、`mono` からの `Element` の推論が絡むと型エラーが読みにくくなることがあります。ここでは素直な方を選んでいます。

**教訓**: ClassyPrelude（や他の代替 Prelude）は便利ですが、名前が同じで型が違う関数があります。困ったら `hiding` して標準版を使うのは、恥ずかしいことではありません。

## 7.3 明示的な再帰 — 途中で止めたいとき

畳み込みでは表現しにくいのが「条件を満たしたら途中で打ち切る」処理です。そこは素直に再帰を書きます。

```haskell
-- src/Sync.hs:199
-- | Run an action over each range in turn, summing the rows written and
-- stopping at the first failure (the Python loop breaks likewise). Rows
-- written before the failure are still reported.
foldRanges :: (Monad m) => (DateRange -> m RangeResult) -> [DateRange] -> m RangeResult
foldRanges run = go 0
  where
    go total [] = return (total, Nothing)
    go total (range:rest) = do
        (rows, merr) <- run range
        case merr of
            Just err -> return (total + rows, Just err)
            Nothing  -> go (total + rows) rest
```

**`go` という名前のローカル再帰関数**は Haskell の定番パターンです。特徴は、

- 累積値（ここでは `total`）を引数で持つ（アキュムレータ）
- 外側の関数の引数（`run`）はクロージャで捕まえるので、再帰の引数に含めない
- 終了条件を最初の等式に書く

`foldM` でも書けなくはありませんが、「エラーが出たら残りをスキップ」を表現するには `Either` を畳み込み値に含めるなどの工夫が要り、かえって読みにくくなります。**明示的な再帰は敗北ではありません。** 制御構造がライブラリ関数と合わないときは、そのまま書くのが正解です。

### 逆方向に進む再帰

心拍取得は「新しい方から古い方へ 30 日ずつ遡る」という珍しいループです。

```haskell
-- src/Sync.hs:274
-- Heartrate: each fetch range is walked backwards in <=30-day windows.
syncHeartrateRange (DateRange fetchStart fetchEnd) = go 0 fetchEnd
  where
    go total windowEnd = do
        let windowStart = max fetchStart (addDaysT (-29) windowEnd)
        r <- tryOura HeartrateSeries $ do
            recs <- liftIO $ Oura.getHeartrate client (DateRange windowStart windowEnd)
            rows <- upsertHeartrateBatch (map toHrPair recs)
            updateSyncLog HeartrateSeries fetchEnd
            return rows
        case r of
            Left msg -> return (total, Just msg)
            Right rows
                | windowStart <= fetchStart -> return (total + rows, Nothing)
                | otherwise -> go (total + rows) (addDaysT (-1) windowStart)
```

読みどころ:

- `max fetchStart (addDaysT (-29) windowEnd)` で、**窓が開始日を超えないようにクランプ**している。ここを忘れると余計な範囲を取りに行く。
- 終了条件が 2 つある（エラー、または開始日に到達）。ガード（`|`）で並べると、それぞれの条件が対等に見えて読みやすい。
- 30 日窓なのに `-29` なのは、**両端を含む**範囲だから。`2024-01-01` から `2024-01-30` は 30 日間で、差は 29。オフザイワン（off-by-one）を疑うべき箇所で、テストが固定しています。

```haskell
-- test/SyncSpec.hs:189
it "heartrate window capped at 30 days" $ do
    calls <- runMem $ ...
    forM_ (callsFor "heartrate" calls) $ \(DateRange s e) ->
        diffDaysT e s `shouldSatisfy` (<= 29)
```

**境界値の意図はテストに書く。** コメントで「30日窓だから -29」と書くより、テストで固定する方が壊れたときに気づけます。

### ページネーションの再帰

```haskell
-- src/Oura.hs:80
-- Follow next_token pagination, concatenating each page's data array.
getPaged :: Text -> [(Text, Text)] -> IO [Value]
getPaged path params = go Nothing []
  where
    go mnext acc = do
        let queryParams = params ++ maybe [] (\t -> [("next_token", t)]) mnext
        body <- httpGet path queryParams
        let page = fromMaybe [] (jsonArray =<< jsonLookup "data" body)
            acc' = acc ++ page
        writeLog appLog LevelDebug (...)
        maybe (return acc') (\t -> go (Just t) acc')
              (jsonText =<< jsonLookup "next_token" body)
```

「`next_token` があれば次ページ、なければ終わり」の再帰です。最後の行の `maybe (return acc') (\t -> go (Just t) acc')` は、第 7.2 節の `maybe id f` と同じ形——**`Maybe` を「続けるか終わるか」の分岐に使う**慣用句です。

ここに 1 つ性能上の注意があります。`acc' = acc ++ page` は、**毎回 `acc` 全体を辿ります**。ページ数を n とすると O(n²) です。ページが数十なら問題ありませんが、数千ページになると効きます。

対処は次節で扱う「逆順に積んで最後に反転」です。

## 7.4 リストの `++` に注意する

Haskell のリストは単方向連結リストです。`xs ++ ys` のコストは `length xs` に比例します。したがって、

```haskell
acc = acc ++ [newItem]   -- 毎回 O(length acc) → 全体で O(n²)
```

は典型的なアンチパターンです。このコードベースには 3 箇所あります。

**(1) `Oura.getPaged` の `acc ++ page`**（上述）

**(2) `Db.getDailyMetricsBulk` の集約**

```haskell
-- src/Db.hs:118
-- The query is ordered by (metric, day) and @flip (++)@ appends, so
-- each metric keeps its rows in day order. Union with the all-metrics
-- map (left-biased) gives metrics without rows an empty list.
let byMetric = M.fromListWith (flip (++))
        [ (metric, [mergeRow day score (parseDataJson dj)])
        | (Single name, Single day, Single score, Single dj) <- rows
        , Just metric <- [parseDailyMetric name] ]
```

`M.fromListWith f` は、キーが衝突したとき `f new old` を呼びます。GHCi で確かめられます。

```
> Data.Map.toList (Data.Map.fromListWith (flip (++)) [(1,"a"),(1,"b"),(1,"c")])
[(1,"abc")]
> Data.Map.toList (Data.Map.fromListWith (++) [(1,"a"),(1,"b"),(1,"c")])
[(1,"cba")]
```

`flip (++)` を使うことで挿入順（＝SQL の `ORDER BY metric, day`）が保たれます。正しい結果を出しますが、`old ++ new` は `old` を毎回辿るので、1 メトリックあたりの行数の二乗に比例します。14〜30 日分なら無害ですが、長期間を扱うようになると劣化します。

**(3) テストスタブの記録**

```haskell
-- test/SyncSpec.hs:48
rec metric records range = do
    modifyIORef' ref (++ [(metric, range)])
    return records
```

テストコードなので実害はありませんが、同じ形です。

### 正しい書き方

**逆順に積んで最後に反転する**のが定石です。

```haskell
-- getPaged の改善案
go mnext acc = do
    ...
    let acc' = page : acc          -- リストのリストとして先頭に積む（O(1)）
    ...
    maybe (return (concat (reverse acc'))) (\t -> go (Just t) acc') ...
```

```haskell
-- getDailyMetricsBulk の改善案
let byMetric = M.map reverse $ M.fromListWith (++) [ ... ]
```

`fromListWith (++)` は `new ++ old` なので結果が逆順になりますが、`new` は常に 1 要素リストなので `++` のコストは O(1)。最後に一度 `reverse`（O(n)）すれば全体 O(n) です。

より本格的には `Data.Sequence`（両端 O(1) 追加）や `Data.DList` を使います。ただし**このアプリの規模では過剰**なので、`reverse` 方式で十分でしょう。第 13 章の演習 4 で実際に直します。

**判断の指針**: 「後ろに追加」を繰り返す構造を見たら、まず要素数の上限を見積もる。数十なら放置、数千以上なら直す。**推測せず、データの実際の規模で決める。**

## 7.5 隣接要素でグループ化する

```haskell
-- src/Sync.hs:179
-- | Group consecutive missing days into (start, end) ranges. @days@ is a
-- contiguous run of dates, so every maximal group of missing days is exactly
-- one range — including a group that runs to the final day (always @today@,
-- which is always missing).
collectGaps :: (DayText -> Bool) -> [DayText] -> [DateRange]
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
  where
    gapRange grp = case grp of
        (d:_) | isMissing d -> DateRange d <$> lastMay grp
        _                   -> Nothing
```

3 つの部品を合成しています。

**(1) `groupBy ((==) `on` isMissing)`**

`on :: (b -> b -> c) -> (a -> b) -> a -> a -> c` は、`(f `on` g) x y = f (g x) (g y)` です。ここでは「`isMissing` の結果が等しい隣接要素をまとめる」。

```
入力:  [埋, 埋, 欠, 欠, 埋, 欠]
結果:  [[埋,埋], [欠,欠], [埋], [欠]]
```

`groupBy` は**隣接要素だけを見る**（ソートしない）ことに注意してください。連続した欠損日をまとめたい今回の用途にはこれが正解です。「名前から推測せず型と挙動を確認する」の実例です。

**(2) `gapRange` で欠損グループだけを範囲に変換**

```haskell
(d:_) | isMissing d -> DateRange d <$> lastMay grp
```

グループの先頭が欠損なら、`DateRange 先頭 末尾` を作る。`lastMay :: MonoFoldable mono => mono -> Maybe (Element mono)` は空リストで `Nothing` を返す安全版です。標準 Prelude の `last` は空リストで例外を投げます。ClassyPrelude はそれを隠し、`lastMay` を提供します（第 12 章）。

`DateRange d <$> lastMay grp` は `Maybe DateRange` になります。`groupBy` の結果に空グループは含まれないので実際には常に `Just` ですが、**部分関数を避けて `Maybe` にしておく**ことで、`error` の可能性が構造的に消えます。

**(3) `mapMaybe` で `Nothing` を捨てる**

`mapMaybe :: (a -> Maybe b) -> [a] -> [b]`。変換と filter を同時に行う関数です。

### 合成として書く効果

この関数は `mapMaybe f . groupBy g` という **ポイントフリー（引数を書かない）合成**です。`days` という引数名が現れません。

```haskell
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
```

ポイントフリーは常に良いわけではなく、やりすぎると暗号になります。ここでは 2 段の合成で、「グループ化してから変換する」というデータの流れがそのまま読めるので適切です。

**目安**: 合成が 2〜3 段まで、途中で引数の順序をこねる必要がない（`flip`、`uncurry` の多用がない）なら、ポイントフリーの方が読みやすい。それを超えたら引数を書く。

## 7.6 この章のまとめ

| やりたいこと | 使うもの | このプロジェクトの例 |
|---|---|---|
| フィルタしつつ変換 | リスト内包表記 / `mapMaybe` | `Sync.hs:112`, `Db.hs:67` |
| 効果つきで畳み込む | `foldM` | `runSync` のメトリックループ |
| 途中で打ち切る | 明示的な `go` 再帰 | `foldRanges`, `syncHeartrateRange` |
| 終了条件が外部データ | 明示的な `go` 再帰 | `getPaged`（ページネーション） |
| 隣接要素のグループ化 | `groupBy` + `on` | `collectGaps` |
| `Maybe` で分岐 | `maybe f g` | `maybe id (M.insert metric) merr` |

- ループを書く前に、内包表記とライブラリ関数で済まないか考える。
- 明示的な再帰は最後の手段だが、制御構造が特殊なら堂々と使う。アキュムレータは引数に。
- `xs ++ [x]` の繰り返しは O(n²)。データ量を見積もり、必要なら「逆順に積んで反転」に直す。
- 関数名から挙動を推測しない（`groupBy` は隣接のみ、`fromListWith f` は `f new old`）。GHCi で確認する。

## 演習

1. `M.fromListWith` の引数順を GHCi で確認し、`Db.getDailyMetricsBulk` を `M.map reverse $ M.fromListWith (++) ...` に書き換えてください。`stack test` が通ることを確認してください（`test/DbSpec.hs` に順序を検証するケースがあるか探すこと）。

2. `collectGaps` を `groupBy` を使わずに書き直してください（明示的な再帰、または `foldr`）。どちらが読みやすいですか。行数はどうなりますか。

3. `getPaged` を「逆順に積んで最後に `concat . reverse`」の形に書き換えてください。ログ出力（`length acc'` を使っている）はどう変わりますか。ログの意味を保つにはどうすればよいですか。
