# 第 6 章 純粋な芯と効果の殻

← [第5章 型クラスと制約](05-typeclasses.md) | [目次](README.md) | [第7章 失敗の表現を選ぶ](07-failure-modes.md) →

> **この章で復習する文法**: `do` 記法の脱糖（`>>=` との対応）、`do` 内の `let` と `<-` の違い、`Maybe` モナドの `do`、`forM_` / `when` / `unless`、参照透過性

「純粋関数を使いましょう」は入門書に必ず書いてあります。しかし実務のアプリは HTTP を叩き、DB に書き、時計を読み、ログを出します。**どこまでを純粋に保ち、どこから効果を許すか**の線引きこそが設計です。

この章では、`do` 記法の正体を確認したうえで、このプロジェクトが実際にどこへ線を引いたかを見ます。

## 目次

- [6.1 `do` 記法の正体](#61-do-記法の正体)
  - [`<-` と `let` の違い](#-と-let-の違い)
  - [`do` は `IO` 専用ではない](#do-は-io-専用ではない)
  - [文法メモ: `forM_` / `when` / `unless`](#文法メモ-form_-when-unless)
- [6.2 判断は純粋関数に、入出力は外側に](#62-判断は純粋関数に入出力は外側に)
  - [文法メモ: `maybe` と `($ range)`](#文法メモ-maybe-と-range)
- [6.3 時刻を引数にする](#63-時刻を引数にする)
- [6.4 「純粋にできるところ」を見つける](#64-純粋にできるところを見つける)
- [6.5 文字列生成も純粋に](#65-文字列生成も純粋に)
- [6.6 効果を持つ関数にも「必要最小限の制約」がある](#66-効果を持つ関数にも必要最小限の制約がある)
- [6.7 この章のまとめ](#67-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 6.1 `do` 記法の正体

`do` はモナドの糖衣構文です。次の 3 つの規則だけで脱糖できます。

```haskell
do { x <- m; rest }     ==  m >>= \x -> do { rest }
do { m; rest }          ==  m >>  do { rest }
do { let x = e; rest }  ==  let x = e in do { rest }
```

最後の式が全体の値になります。実物で確かめます。

```haskell
-- src/Foundation.hs:179
requireAuth :: Handler ()
requireAuth = do
    authed <- isAuthenticated
    unless authed $
        sendStatusJSON status401 (A.object ["error" A..= ("Unauthorized" :: Text)])
```

これは

```haskell
requireAuth =
    isAuthenticated >>= \authed ->
        unless authed (sendStatusJSON status401 (...))
```

と同じです。**`<-` は「代入」ではありません。** `m >>= \x -> ...` の左辺に名前を付ける記法であり、`m` の型が `Handler Bool` なら `x` の型は `Bool` になる、という「1 段はがす」操作です。

### `<-` と `let` の違い

```haskell
-- src/Sync.hs:89
findMissingRange today metric requestedEnd = do
    mlast <- getLastSyncedDay metric      -- 効果のある計算から値を取り出す
    let end = min requestedEnd today      -- 純粋な式に名前を付ける
    case mlast of
        ...
```

- `x <- m` — `m` は**そのモナドの計算**。実行して結果を束縛する。
- `let x = e` — `e` は**ただの式**。評価すらまだされない（遅延評価）。

型を見れば迷いません。右辺が `m a` の形なら `<-`、それ以外なら `let` です。

### `do` は `IO` 専用ではない

ここが実務で効くポイントです。**任意のモナドで `do` が使えます。**

```haskell
-- src/Sync.hs:69
Resilience  -> do
    level <- jsonText =<< jsonLookup "level" record
    A.Number . fromIntegral <$> lookup level resilienceLevelOrder
```

これは `Maybe` モナドの `do` です。IO は 1 つも起きていません。意味は「`level` フィールドがあり、それが文字列で、かつ既知のレベル名なら数値を返す。どこかで失敗したら `Nothing`」。

同じことを `case` の入れ子で書くとこうなります。

```haskell
-- 同じ意味だが読みにくい
case jsonLookup "level" record of
    Just v -> case jsonText v of
        Just level -> case lookup level resilienceLevelOrder of
            Just n  -> Just (A.Number (fromIntegral n))
            Nothing -> Nothing
        Nothing -> Nothing
    Nothing -> Nothing
```

**`Maybe` の `do` で入れ子の分岐を平坦化する**のは、実務コードで最も費用対効果が高いテクニックの一つです。「失敗したら以降を飛ばす」が `>>=` の定義そのものなので、書かなくてよくなります。

### 文法メモ: `forM_` / `when` / `unless`

`do` の中の「ループ」と「条件実行」です。

```haskell
-- src/Sync.hs:114
forM_ dated $ \(day, r) ->
    upsertDailyMetric metric day (jsonDouble =<< extractScore metric r) r

-- src/Sync.hs:116
when (metric == Readiness && not (null records)) $ do
    forM_ dated (uncurry writeTemperature)
    updateSyncLog (Daily Temperature) end
```

- `forM_ :: (MonoFoldable mono, Applicative m) => mono -> (Element mono -> m ()) -> m ()` — 各要素に効果を適用し、結果は捨てる。base の `Data.Foldable.forM_ :: (Foldable t, Monad m) => t a -> (a -> m b) -> m ()` とは型が異なる点に注意（第 5 章で触れた `Foldable`/`MonoFoldable` の違いがここにも出てきます）。このプロジェクトは `ClassyPrelude` を import しているので、実際に使われているのは前者です
- `when` / `unless` — 条件が真（偽）のときだけ実行する

`_` 付きは「結果を集めない」版です（結果が欲しいなら `forM` / `mapM`）。**結果を使わないのに `forM` を使うと、不要なリストが作られます**（`-Wall` は教えてくれません）。

`uncurry writeTemperature` は、`(a, b)` のタプルを受け取る関数に変換する定型です（`uncurry f (x, y) = f x y`）。

## 6.2 判断は純粋関数に、入出力は外側に

同期処理の中心は `syncDailyMetric` です。

```haskell
-- src/Sync.hs:106
syncDailyMetric
    :: (MonadIO m, MonadLogger m)
    => OuraClient -> DailyMetric -> DateRange
    -> ReaderT SqlBackend m Int
syncDailyMetric client metric range@(DateRange start end) = do
    records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
    let dated = [ (day, r) | r <- records, Just day <- [recordDay r] ]
        count = length dated
    forM_ dated $ \(day, r) ->
        upsertDailyMetric metric day (jsonDouble =<< extractScore metric r) r
    ...
```

この関数は効果に満ちています（HTTP 取得、DB 書き込み、ログ）。しかし**判断ロジックは 1 行も含んでいません**。判断はすべて純粋関数に切り出されています。

```haskell
-- src/Sync.hs:60 — 「このメトリックのスコアはどのフィールドか」
extractScore :: DailyMetric -> Value -> Maybe Value

-- src/Sync.hs:77 — 「このレコードは何日のものか」
recordDay :: Value -> Maybe DayText

-- src/Sync.hs:140 — 「このメトリックはどの API で取るか」
fetchFn :: OuraClient -> DailyMetric -> Maybe (DateRange -> IO [Value])
```

シグネチャに `IO` も `m` も出てこない関数が、アプリの意思決定を担っています。これらは GHCi でそのまま呼べ、テストでも DB もネットワークも要りません。

```haskell
-- test/SyncSpec.hs:112 — 純粋関数のテストは 1 行
it "spo2 nested average" $
    extractScore Spo2 (obj ["spo2_percentage" .= obj ["average" .= (98.5 :: Double)]])
        `shouldBe` n 98.5
```

`SyncSpec.hs` の `extract_score` ブロックは 12 ケースありますが、どれも DB を立ち上げません。**純粋関数の比率が高いほど、テストは速く、書くのが楽になります。**

### 文法メモ: `maybe` と `($ range)`

```haskell
records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
```

密度の高い 1 行なので分解します。

- `fetchFn client metric :: Maybe (DateRange -> IO [Value])` — 取得関数があるか
- `maybe :: b -> (a -> b) -> Maybe a -> b` — 「無いとき」「あるときの変換」「対象」
- `($ range)` — セクション記法。「関数を受け取って `range` に適用する」関数、すなわち `\f -> f range`

つまり「取得関数がなければ空リスト、あればそれを `range` に適用する」。`case` で書けば 3 行になります。**`maybe f g` は `Maybe` を潰す定型**として読めるようにしておいてください。

## 6.3 時刻を引数にする

このコードベースで最も実践的な判断がこれです。

```haskell
-- src/Sync.hs:215
runSync
    :: (MonadUnliftIO m, MonadLogger m)
    => DayText                -- ^ today
    -> OuraClient
    -> Maybe DayText          -- ^ requested_start
    ...
```

**「今日」を関数の中で取らず、引数で受け取っています。** `getCurrentTime` を `runSync` の中で呼べば引数は 1 つ減りますが、次を失います。

- テストで「2024-01-31 だったら」を再現できない（`test/SyncSpec.hs` は全ケースで日付を固定しています）
- 呼び出し側がタイムゾーンを選べない

実際、2 つのエントリポイントは異なる「今日」を渡しています。

```haskell
-- src/DailySync.hs:35 — cron は JST の今日
todayJst :: IO DayText
todayJst = todayIn (hoursToTimeZone 9)
```

```haskell
-- src/Handler/Api.hs:109 — Web は UTC の今日
today <- todayUtc
```

（この不一致自体は既知のバグの種で、第 16 章で扱います。しかし**バグが「どこで今日を決めたか」を追える形で存在している**のは、時刻を引数化したおかげです。中で `getCurrentTime` を呼んでいたら、原因箇所の特定はずっと困難でした。）

一般則として、次のものは引数で受け取るか、注入可能な形にします。

- 現在時刻
- 乱数（`Advice.createAdviceJob` の UUID 生成は `IO` に残っていますが、ジョブ ID は外から観測しないので許容範囲）
- 環境変数・設定（`AppSettings` としてまとめて渡す）
- 外部サービスのクライアント（第 10 章）

## 6.4 「純粋にできるところ」を見つける

一見 IO が必要に見えて、実は純粋にできる処理は多いです。`backfillRanges` が良い例です。

```haskell
-- src/Sync.hs:157
backfillRanges
    :: (MonadIO m)
    => Metric -> Int -> DayText
    -> ReaderT SqlBackend m [DateRange]
backfillRanges metric backfillDays today = do
    let windowStart = addDaysT (negate (fromIntegral backfillDays - 1)) today
    case metric of
        HeartrateSeries -> return [DateRange windowStart today]
        Daily daily -> do
            rows <- rawSql "SELECT day FROM daily_metrics WHERE ..." [...]
            let existing = setFromList [ d | Single d <- rows ] :: Set DayText
                days = [ formatDay d | d <- [parseDay windowStart .. parseDay today] ]
                isMissing d = not (d `member` existing) || d == today
            return (collectGaps isMissing days)
```

DB アクセスが必要なのは `existing`（既に埋まっている日の集合）を得る部分だけです。**「欠けている日を連続区間にまとめる」というアルゴリズム本体は純粋関数として独立しています。**

```haskell
-- src/Sync.hs:179
collectGaps :: (DayText -> Bool) -> [DayText] -> [DateRange]
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
  where
    gapRange grp = case grp of
        (d:_) | isMissing d -> DateRange d <$> lastMay grp
        _                   -> Nothing
```

この形の利点は 3 つです。

- **判定条件が引数**（`isMissing :: DayText -> Bool`）。DB の話が入っていない。
- **GHCi で試せる。** 述語を変えて挙動を確かめられる。
- 実装を差し替えても、影響範囲がこの関数に閉じる。

`[parseDay windowStart .. parseDay today]` にも注目してください。`Day` は `Enum` のインスタンスなので、**日付の範囲をリストとして書けます**。`[a .. b]` は `enumFromTo a b` の糖衣で、`Int` 以外にも使えます。

> **設計の指針**: DB から取ったデータをどう加工するかを、DB アクセスと同じ `do` ブロックに書き続けると、テストのたびに DB が必要になります。**一度リストに取り出したら、その後の加工は純粋関数に出す。** これだけでテスト容易性が大きく変わります。

## 6.5 文字列生成も純粋に

アドバイス機能のプロンプト生成も、IO を含みません。

```haskell
-- src/Advice.hs:136
buildAdvicePrompt :: A.Value -> Text
buildAdvicePrompt healthData =
    adviceSystemPrompt <> "\n\n```json\n" <> prettyJson <> "\n```"
  where
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }
```

```haskell
-- src/Advice.hs:105
extractKeyFields :: DailyMetric -> A.Value -> A.Value
```

`extractKeyFields` は「メトリックごとにどのフィールドを LLM に渡すか」という**ドメイン知識の塊**です。これが純粋関数なので、プロンプトに何が入るかを確認するのに `claude` CLI も DB も要りません。`cfg = AP.defConfig { ... }` のレコード更新で設定を作っているのも、第 4 章で見た形です。

## 6.6 効果を持つ関数にも「必要最小限の制約」がある

`Sync.hs`（309 行）を分類すると次のようになります。

| 種類 | 主な関数 | おおよその行数 |
|---|---|---|
| 純粋 | `extractScore`, `recordDay`, `fetchFn`, `collectGaps`, `rangeResult`, `resilienceLevelOrder` | 約 80 |
| 効果あり・薄い | `findMissingRange`, `backfillRanges`, `tryOura`, `foldRanges` | 約 70 |
| 効果あり・厚い | `syncDailyMetric`, `runSync` | 約 100 |

`foldRanges` に注目してください。

```haskell
-- src/Sync.hs:199
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

制約が `Monad m` だけです。`IO` でも `ReaderT SqlBackend m` でも `Identity` でも動きます。つまり**「最初の失敗で止めながら畳み込む」という制御構造だけを抽出**していて、DB も HTTP も知りません。

効果を持つ関数を書くときは、「この関数が本当に必要としている能力は何か」を自問してください。`IO` と書けば何でもできますが、`Monad m` や `MonadIO m` に絞れるなら、その分だけ関数の意味が明確になり、再利用範囲が広がります（第 8 章に続きます）。

## 6.7 この章のまとめ

- `do` はモナドの糖衣。`x <- m` は `m >>= \x -> ...` であって代入ではない。
- `<-` の右辺は `m a`、`let` の右辺はただの式。型を見れば迷わない。
- `do` は `IO` 専用ではない。`Maybe` の `do` で入れ子の分岐を平坦化する。
- 判断・変換・整形は純粋関数に切り出す。効果側は「取ってくる」「書き込む」だけを担当する。
- 現在時刻・乱数・設定・外部クライアントは引数として受け取る。テスト可能性はここで決まる。
- DB から取り出したあとの加工は、条件を関数引数にして純粋関数へ出す（`collectGaps`）。
- 効果を持つ関数でも、必要最小限の制約（`Monad m` で足りるか）を考える。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `do { x <- m; ... }` | `m >>= \x -> ...` | `requireAuth` |
| `do { let x = e; ... }` | 純粋な束縛 | `let end = min requestedEnd today` |
| `Maybe` の `do` | 失敗したら以降を飛ばす | `extractScore` の `Resilience` |
| `forM_ xs f` | 各要素に効果を適用（結果は捨てる） | `syncDailyMetric` |
| `when` / `unless` | 条件付き実行 | `requireAuth`, 温度の派生 |
| `uncurry f` | タプルを 2 引数に展開 | `forM_ dated (uncurry writeTemperature)` |
| `maybe d f m` | `Maybe` を潰す | `maybe (return []) ($ range) ...` |
| `($ x)` | セクション（関数側を後で受け取る） | 同上 |
| `[a .. b]` | `Enum` の範囲リスト | `[parseDay windowStart .. parseDay today]` |

---

← [第5章 型クラスと制約](05-typeclasses.md) | [目次](README.md) | [第7章 失敗の表現を選ぶ](07-failure-modes.md) →
