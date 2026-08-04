# 第 3 章 純粋な芯と効果の殻

「純粋関数を使いましょう」は入門書に必ず書いてあります。しかし実務のアプリは HTTP を叩き、DB に書き、時計を読み、ログを出します。**どこまでを純粋に保ち、どこから IO を許すか**の線引きこそが設計です。

この章では、このプロジェクトが実際にどこに線を引いたかを見ます。

## 3.1 判断は純粋関数に、入出力は外側に

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
    extractScore Spo2 (obj ["spo2_percentage" .= obj ["average" .= (98.5 :: Double)]]) `shouldBe` n 98.5
```

`SyncSpec.hs` の `extract_score` ブロックは 12 ケースありますが、どれも DB を立ち上げません。**純粋関数の比率が高いほど、テストは速く、書くのが楽になります。**

### `extractScore` の中身を読む

```haskell
-- src/Sync.hs:60
extractScore :: DailyMetric -> Value -> Maybe Value
extractScore metric record = case metric of
    Sleep       -> jsonLookup "score" record
    Readiness   -> jsonLookup "score" record
    Activity    -> jsonLookup "score" record
    Stress      -> jsonLookup "stress_high" record
    Spo2        -> case jsonLookup "spo2_percentage" record of
        Just nested@(A.Object _) -> jsonLookup "average" nested
        other                    -> other
    Resilience  -> do
        level <- jsonText =<< jsonLookup "level" record
        A.Number . fromIntegral <$> lookup level resilienceLevelOrder
    CardiovascularAge -> jsonLookup "vascular_age" record
    Temperature       -> jsonLookup "temperature_deviation" record
    VO2Max            -> Nothing
```

読みどころが 3 つあります。

**(1) `Spo2` の `nested@(A.Object _)` パターン。** `@` は「パターンにマッチさせつつ全体にも名前を付ける」記法（as パターン）です。Oura API は `spo2_percentage` をオブジェクトで返すこともスカラーで返すこともあるため、オブジェクトなら `average` を掘り、それ以外はそのまま返します。移植元の Python の挙動を保ったまま、分岐が型で明示されています。

**(2) `Resilience` の `do` ブロックは `Maybe` モナド。** `IO` ではありません。

```haskell
Resilience  -> do
    level <- jsonText =<< jsonLookup "level" record   -- Maybe Text
    A.Number . fromIntegral <$> lookup level resilienceLevelOrder
```

「`level` フィールドがあり、かつそれが文字列で、かつ既知のレベル名なら数値を返す」を、`Maybe` の `do` で書いています。同じことを `case` の入れ子で書くと 3 段になります。

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

**`do` 記法は IO 専用ではありません。** `Maybe`、`Either`、リストなど、あらゆるモナドで「失敗したら以降を飛ばす」を平坦に書くために使えます。実務コードで最も費用対効果が高いテクニックの一つです。

**(3) `=<<` の向き。** `jsonText =<< jsonLookup "level" record` は `jsonLookup "level" record >>= jsonText` と同じです。左向きに書くと、`f =<< g =<< h x` のように「関数適用の順（右から左）」に読めるので、`.` による関数合成と目線の向きが揃います。

## 3.2 時刻を引数にする

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

- テストで「2024-01-31 だったら」を再現できない（`test/SyncSpec.hs` は全ケースで日付を固定している）
- 呼び出し側がタイムゾーンを選べない

実際、この 2 つのエントリポイントは異なる「今日」を渡しています。

```haskell
-- src/DailySync.hs:35 — cron は JST の今日
todayJst :: IO DayText
todayJst = todayIn (hoursToTimeZone 9)
```

```haskell
-- src/Handler/Api.hs:109 — Web は UTC の今日
today <- todayUtc
```

（ちなみにこの不一致自体は既知のバグの種で、第 13 章の演習 2 で扱います。しかし**バグが「どこで今日を決めたか」を追える形で存在している**のは、時刻を引数化したおかげです。中で `getCurrentTime` を呼んでいたら、原因箇所の特定はずっと難しくなります。）

一般則として、次のものは引数で受け取るか、注入可能な形にします。

- 現在時刻
- 乱数（`Advice.createAdviceJob` の UUID 生成は `IO` に残っているが、ジョブ ID は外から観測する必要がないため許容範囲）
- 環境変数・設定（`AppSettings` としてまとめて渡す）
- 外部サービスのクライアント（第 6 章）

## 3.3 「純粋にできるところ」を見つける

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

この形の何が良いか。

- **判定条件が引数**（`isMissing :: DayText -> Bool`）。DB の話が入っていない。
- **GHCi で試せる。** `collectGaps (`elem` ["b","d"]) ["a","b","c","d"]` を評価すればすぐ挙動が分かる。
- 実装を変えても（第 13 章演習 4 のような性能改善）、影響範囲がこの関数に閉じる。

「DB から取ったデータをどう加工するか」を DB アクセスと同じ `do` ブロックに書き続けると、テストのたびに DB が必要になります。**一度リストに取り出したら、その後の加工は純粋関数に出す。** これだけでテスト容易性が大きく変わります。

## 3.4 文字列生成も純粋に

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
extractKeyFields metric row =
    let g k = fromMaybe A.Null (jsonLookup k row)
        base = [("day", g "day"), ("score", g "score")]
        extra = case metric of
            Sleep       -> [("contributors", g "contributors")]
            ...
    in A.Object (KM.fromList (base ++ extra))
```

`extractKeyFields` は「メトリックごとにどのフィールドを LLM に渡すか」という**ドメイン知識の塊**です。これが純粋関数なので、プロンプトに何が入るかを確認するのに `claude` CLI も DB も要りません。

`where` の中で `g k = fromMaybe A.Null (jsonLookup k row)` とローカル関数を定義しているのも実務的です。同じパターンが 10 回出るなら、短い名前のローカル関数にまとめる。ただし**モジュール全体に公開するほどではない**ので `let` / `where` に置く。この使い分けができると、コードの見通しが一段良くなります。

## 3.5 効果を含む関数の分量を見る

「純粋な芯・効果の殻」がどれくらい実現できているかは、行数で大まかに測れます。このプロジェクトの `Sync.hs`（309 行）を分類すると:

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

制約が `Monad m` だけです。`IO` でも `ReaderT SqlBackend m` でも、`Identity` でも動きます。つまり**「最初の失敗で止めながら畳み込む」という制御構造だけを抽出**していて、DB も HTTP も知りません。テストで純粋なモナドを渡して検証することもできます。

効果を持つ関数を書くときは、「この関数が本当に必要としている能力は何か」を自問してください。`IO` と書いてしまうと何でもできますが、`Monad m` や `MonadIO m` に絞れるなら、その分だけ関数の意味が明確になり、再利用範囲が広がります（第 5 章に続く）。

## 3.6 この章のまとめ

- 判断・変換・整形は純粋関数に切り出す。IO は「取ってくる」「書き込む」だけを担当する。
- `do` は IO 専用ではない。`Maybe` の `do` で入れ子の分岐を平坦化する。
- 現在時刻・乱数・設定・外部クライアントは引数として受け取る。テスト可能性はここで決まる。
- DB から取り出したあとの加工は、条件を関数引数にして純粋関数へ出す（`collectGaps`）。
- 効果を持つ関数でも、必要最小限の制約（`Monad m` で足りるか）を考える。

## 演習

1. `collectGaps` を GHCi で動かしてください。`isMissing` を色々変え、「先頭が欠け」「末尾が欠け」「全部埋まっている」の各ケースで何が返るか確認してください。

   ```sh
   stack ghci oura-dashboard-hs:lib
   ```
   `collectGaps` は export されていないため、そのままでは呼べません。どうすれば呼べるか（export リストに追加する／`Sync.hs` を直接 `:load` する）も含めて考えてください。これは第 1 章の「export リストは契約」と、テスト容易性のトレードオフの実例です。

2. `syncDailyMetric` の中の `writeTemperature`（`src/Sync.hs:124`）は `where` にあるローカル関数です。これを純粋関数（`Value -> A.Value` を返す形）とDB書き込みに分けるとしたら、どう分割しますか。分けることで何がテストできるようになりますか。

3. `Db.mergeRow`（`src/Db.hs:41`）と `Db.parseDataJson`（`src/Db.hs:33`）は純粋関数ですが、`Db.hs` に置かれています。これらを別モジュールに出すべきか、現状のままで良いか、理由とともに述べてください。
