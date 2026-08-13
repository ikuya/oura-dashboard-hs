# 第 9 章 再帰・畳み込み・遅延評価

← [第8章 モナド変換子と制約の実務](08-monad-transformers.md) | [目次](README.md) | [第10章 関数のレコードによる依存性注入](10-dependency-injection.md) →

> **この章で復習する文法**: リスト内包表記、`mapMaybe` / `groupBy` / `on`、`foldM`、アキュムレータ付きの `go` 再帰、`maybe f g` の慣用句、リストの `++` のコスト、遅延評価と正格版（`'` 付き関数）

命令型言語から来た人が Haskell で最初に戸惑うのは「ループが書けない」ことです。実際には、ループに相当する道具が用途別に分かれているだけです。この章では、このプロジェクトが使っている 5 つの形を、選択理由とともに見ます。

## 目次

- [9.1 まず内包表記とライブラリ関数を試す](#91-まず内包表記とライブラリ関数を試す)
  - [文法メモ: 内包表記の構成要素](#文法メモ-内包表記の構成要素)
- [9.2 `foldM` — 効果を伴う畳み込み](#92-foldm-効果を伴う畳み込み)
  - [`maybe id (M.insert metric) merr` を読む](#maybe-id-minsert-metric-merr-を読む)
  - [`ClassyPrelude` の `foldM` を避けている理由](#classyprelude-の-foldm-を避けている理由)
- [9.3 明示的な再帰 — 途中で止めたいとき](#93-明示的な再帰-途中で止めたいとき)
  - [逆方向に進む再帰](#逆方向に進む再帰)
  - [ページネーションの再帰](#ページネーションの再帰)
- [9.4 隣接要素でグループ化する](#94-隣接要素でグループ化する)
- [9.5 `++` のコストと遅延評価](#95-のコストと遅延評価)
  - [正しい書き方](#正しい書き方)
  - [遅延評価と正格版](#遅延評価と正格版)
- [9.6 この章のまとめ](#96-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 9.1 まず内包表記とライブラリ関数を試す

ループを書く前に、既存の関数で済まないかを考えます。

```haskell
-- src/Sync.hs:112
let dated = [ (day, r) | r <- records, Just day <- [recordDay r] ]
```

「レコードのうち `day` フィールドを持つものだけを、`(日付, レコード)` のペアにする」。フィルタと変換を同時に行っています。第 2 章で見たとおり、`Just day <- [recordDay r]` は**マッチしない要素を捨てる**ジェネレータです。

同じことは `mapMaybe` でも書けます。

```haskell
mapMaybe (\r -> (,) <$> recordDay r <*> Just r) records
```

どちらが読みやすいかは好みですが、「フィルタしながら変換する」ことを一目で伝えるという点で内包表記が選ばれています。

他の実例:

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

### 文法メモ: 内包表記の構成要素

```haskell
[ 出力式 | ジェネレータ, 述語, let 束縛, ... ]
```

- ジェネレータ `p <- xs` — パターンにマッチしない要素は捨てられる
- 述語 `cond` — `False` の要素は捨てられる
- `let x = e` — 途中で名前を付けられる（`in` は不要）
- ジェネレータを複数書くと直積（入れ子ループ）になる

## 9.2 `foldM` — 効果を伴う畳み込み

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

`foldM :: Monad m => (b -> a -> m b) -> b -> t a -> m b` は、命令型で書けば

```python
result = SyncResult({}, {})
for metric in targets:
    result = step(result, metric)   # DB アクセスや HTTP を含む
```

に相当します。違いは、`result` が再代入される変数ではなく、各ステップの戻り値である点だけです。

### `maybe id (M.insert metric) merr` を読む

初見では読みにくい式です。分解します。

- `maybe :: b -> (a -> b) -> Maybe a -> b`
- ここでの `b` は `Map Metric Text -> Map Metric Text`（**関数**）
- `merr` が `Nothing` なら `id`（何もしない関数）
- `merr` が `Just err` なら `M.insert metric err`（挿入する関数）
- 最後にその関数を `(syncErrors acc)` に適用

つまり **「エラーがあれば挿入、なければそのまま」**。`case` で書くとこうなります。

```haskell
syncErrors = case merr of
    Nothing  -> syncErrors acc
    Just err -> M.insert metric err (syncErrors acc)
```

`maybe id f` は Haskell の慣用句で、慣れれば 1 行で読めます。ただし**慣用句を知らない読み手には不親切**でもあります。チームの習熟度で決めるべき類の判断ですが、読めるようにはなっておいてください。同じ形は頻出します。

### `ClassyPrelude` の `foldM` を避けている理由

```haskell
-- src/Sync.hs:26
import ClassyPrelude hiding (foldM)
...
import Control.Monad (foldM)
```

GHCi で両者を比べると理由が見えます。

```
ClassyPrelude.foldM  :: (MonoFoldable mono, Monad m) => (a -> Element mono -> m a) -> a -> mono -> m a
Control.Monad.foldM  :: (Foldable t, Monad m) => (b -> a -> m b) -> b -> t a -> m b
```

使い勝手はほぼ同じですが、ClassyPrelude 版は `mono` からの `Element` の推論が絡むため、型エラーが読みにくくなることがあります。ここでは素直な方を選んでいます。

> **教訓**: 代替 Prelude は便利ですが、名前が同じで型が違う関数があります。困ったら `hiding` して標準版を使うのは、恥ずかしいことではありません。

## 9.3 明示的な再帰 — 途中で止めたいとき

畳み込みでは表現しにくいのが「条件を満たしたら打ち切る」処理です。そこは素直に再帰を書きます。

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

**`go` という名前のローカル再帰関数**は Haskell の定番パターンです。特徴は 3 つ。

- 累積値（ここでは `total`）を引数で持つ（アキュムレータ）
- 外側の関数の引数（`run`）はクロージャで捕まえるので、再帰の引数に含めない
- 終了条件を最初の等式に書く

`foldM` でも書けなくはありませんが、「エラーが出たら残りをスキップ」を表現するには畳み込み値に `Either` を含めるなどの工夫が要り、かえって読みにくくなります。**明示的な再帰は敗北ではありません。** 制御構造がライブラリ関数と合わないときは、そのまま書くのが正解です。

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

- `max fetchStart (addDaysT (-29) windowEnd)` で、**窓が開始日を超えないようにクランプ**している。
- 終了条件が 2 つある（エラー、または開始日に到達）。ガードで並べると、それぞれの条件が対等に見えて読みやすい。
- 30 日窓なのに `-29` なのは、**両端を含む**範囲だから。`2024-01-01` から `2024-01-30` は 30 日間で、差は 29。オフバイワンを疑うべき箇所で、テストが固定しています。

```haskell
-- test/SyncSpec.hs:189
it "heartrate window capped at 30 days" $ do
    calls <- runMem $ ...
    forM_ (callsFor "heartrate" calls) $ \(DateRange s e) ->
        diffDaysT e s `shouldSatisfy` (<= 29)
```

**境界値の意図はテストに書く。** コメントで「30 日窓だから -29」と書くより、テストで固定する方が壊れたときに気づけます。

### ページネーションの再帰

```haskell
-- src/Oura.hs:81
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

「`next_token` があれば次ページ、なければ終わり」の再帰です。最後の `maybe (return acc') (\t -> go (Just t) acc')` は 9.2 の `maybe id f` と同じ形——**`Maybe` を「続けるか終わるか」の分岐に使う**慣用句です。

ここには性能上の注意が 1 つあります。次節で扱います。

## 9.4 隣接要素でグループ化する

```haskell
-- src/Sync.hs:179
collectGaps :: (DayText -> Bool) -> [DayText] -> [DateRange]
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
  where
    gapRange grp = case grp of
        (d:_) | isMissing d -> DateRange d <$> lastMay grp
        _                   -> Nothing
```

3 つの部品の合成です。

**(1) ``groupBy ((==) `on` isMissing)``**

`on :: (b -> b -> c) -> (a -> b) -> a -> a -> c` は ``(f `on` g) x y = f (g x) (g y)``。ここでは「`isMissing` の結果が等しい隣接要素をまとめる」。

```
入力:  [埋, 埋, 欠, 欠, 埋, 欠]
結果:  [[埋,埋], [欠,欠], [埋], [欠]]
```

`groupBy` は**隣接要素だけを見ます**（ソートしません）。連続した欠損日をまとめたい今回の用途にはこれが正解です。「名前から推測せず型と挙動を確認する」の実例でもあります。

**(2) `gapRange` で欠損グループだけを範囲に変換**

`lastMay :: MonoFoldable mono => mono -> Maybe (Element mono)` は空リストで `Nothing` を返す安全版です。標準 Prelude の `last` は空リストで例外を投げますが、ClassyPrelude はそれを隠しています（第 15 章）。

`DateRange d <$> lastMay grp` は `Maybe DateRange` になります。`groupBy` の結果に空グループは含まれないので実際には常に `Just` ですが、**部分関数を避けて `Maybe` にしておく**ことで、例外の可能性が構造的に消えます。

**(3) `mapMaybe` で `Nothing` を捨てる**

`mapMaybe :: (a -> Maybe b) -> [a] -> [b]`。変換とフィルタを同時に行います。

この関数全体は `mapMaybe f . groupBy g` というポイントフリー合成で、引数 `days` が現れません。2 段の合成で「グループ化してから変換する」というデータの流れがそのまま読めるので、ここでは適切な使い方です。

## 9.5 `++` のコストと遅延評価

Haskell のリストは単方向連結リストです。`xs ++ ys` のコストは `length xs` に比例します。したがって

```haskell
acc = acc ++ [newItem]   -- 毎回 O(length acc) → 全体で O(n²)
```

は典型的なアンチパターンです。このコードベースには 3 箇所あります。

**(1) `Oura.getPaged` の `acc ++ page`**（9.3 で引用）。ページ数を n とすると O(n²)。数十ページなら問題ありませんが、数千ページになると効きます。

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

`M.fromListWith f` は、キーが衝突したとき `f 新しい値 既存の値` を呼びます。GHCi で確かめられます。

```
> M.toList (M.fromListWith (++) [(1,"a"),(1,"b"),(1,"c")])
[(1,"cba")]
> M.toList (M.fromListWith (flip (++)) [(1,"a"),(1,"b"),(1,"c")])
[(1,"abc")]
```

`flip (++)` によって挿入順（＝SQL の `ORDER BY metric, day`）が保たれます。正しい結果を出しますが、`old ++ new` は `old` を毎回辿るので、1 メトリックあたりの行数の二乗に比例します。14〜30 日分なら無害ですが、期間を延ばすと劣化します。

**(3) テストスタブの記録**（`test/SyncSpec.hs:49` の `modifyIORef' ref (++ [(metric, range)])`）。テストコードなので実害はありませんが、同じ形です。

### 正しい書き方

**逆順に積んで最後に反転する**のが定石です。

```haskell
-- getDailyMetricsBulk の改善案
let byMetric = M.map reverse $ M.fromListWith (++) [ ... ]
```

`fromListWith (++)` は `new ++ old` を計算し、`new` は常に 1 要素リストなので `++` のコストは O(1)。最後に一度 `reverse`（O(n)）すれば全体 O(n) です。より本格的には `Data.Sequence` や `Data.DList` を使いますが、**このアプリの規模では過剰**でしょう。

> **判断の指針**: 「後ろに追加」を繰り返す構造を見たら、まず要素数の上限を見積もる。数十なら放置、数千以上なら直す。**推測せず、データの実際の規模で決める。**

### 遅延評価と正格版

Haskell の評価は既定で遅延です。`let x = expensive` は、`x` が実際に使われるまで計算されません。これは利点（`[parseDay windowStart .. parseDay today]` のようなリストを気軽に書ける）でもあり、落とし穴（未評価の式＝サンクが溜まる）でもあります。

蓄積する値には**正格版**を使うのが実務の既定です。

```haskell
-- src/Advice.hs:153
atomically $ modifyTVar' jobs (M.insert jid job)

-- test/SyncSpec.hs:49
modifyIORef' ref (++ [(metric, range)])
```

`'` が付いた `modifyTVar'` / `modifyIORef'` は、適用結果を WHNF（弱頭正規形）まで評価します。非正格版だと「あとで計算する式」が積み上がり、メモリを食います（スペースリーク）。

**実務ルール**: `modifyTVar`、`atomicModifyIORef`、`foldl` などに正格版（`'` 付き）があるなら、既定でそちらを使う。遅延が欲しい理由が明確なときだけ非正格版にする。

ただし **「正格版を使えば安心」ではありません**。`modifyTVar' jobs (M.insert jid job)` が評価するのは `Map` の構造までで、`AdviceJob` の中身は遅延したままです。厳密に避けたいならフィールドに `!` を付けます（`data AdviceJob = AdviceJob { jobAdvice :: !Text, ... }`、`BangPatterns` 相当の正格フィールド）。このアプリの規模では実害がないので、そこまではしていません。

`Data.Map.Strict` を使っているのも同じ発想です。

```haskell
-- src/Sync.hs:30
import qualified Data.Map.Strict  as M
```

`Data.Map.Lazy` だと値が未評価のまま Map に入ります。**カウンタや集計結果を入れる Map は Strict 版**、というのが定石です。

## 9.6 この章のまとめ

| やりたいこと | 使うもの | このプロジェクトの例 |
|---|---|---|
| フィルタしつつ変換 | リスト内包表記 / `mapMaybe` | `Sync.hs:112`, `Db.hs:67` |
| 効果つきで畳み込む | `foldM` | `runSync` のメトリックループ |
| 途中で打ち切る | 明示的な `go` 再帰 | `foldRanges`, `syncHeartrateRange` |
| 終了条件が外部データ | 明示的な `go` 再帰 | `getPaged`（ページネーション） |
| 隣接要素のグループ化 | `groupBy` + `on` | `collectGaps` |
| `Maybe` で分岐 | `maybe f g` | `maybe id (M.insert metric) merr` |

- ループを書く前に、内包表記とライブラリ関数で済まないか考える。
- 明示的な再帰は最後の手段だが、制御構造が特殊なら堂々と使う。アキュムレータは引数に持つ。
- `xs ++ [x]` の繰り返しは O(n²)。データ量を見積もり、必要なら「逆順に積んで反転」に直す。
- 関数名から挙動を推測しない（`groupBy` は隣接のみ、`fromListWith f` は `f new old`）。GHCi で確認する。
- 蓄積には正格版（`'` 付き）と `Data.Map.Strict` を既定にする。ただし正格性は「1 段だけ」であることを理解しておく。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `[ e \| p <- xs, cond, let y = e' ]` | リスト内包表記 | `dated`, `valid` |
| `mapMaybe f xs` | 変換とフィルタを同時に | `collectGaps` |
| ``f `on` g`` | 引数を `g` で写してから `f` | ``(==) `on` isMissing`` |
| `groupBy p xs` | **隣接**要素のグループ化 | `collectGaps` |
| `foldM f z xs` | 効果つき畳み込み | `runSync` |
| `where go acc [] = ...` | アキュムレータ付き再帰 | `foldRanges`, `getPaged` |
| `maybe d f m` | `Maybe` の分岐（関数を返すことも多い） | `maybe id (M.insert m) merr` |
| `modifyTVar'` / `modifyIORef'` / `foldl'` | 正格版 | `Advice.hs`, `SyncSpec.hs` |
| `Data.Map.Strict` | 値を正格に保つ Map | `Sync.hs`, `Db.hs` |

---

← [第8章 モナド変換子と制約の実務](08-monad-transformers.md) | [目次](README.md) | [第10章 関数のレコードによる依存性注入](10-dependency-injection.md) →
