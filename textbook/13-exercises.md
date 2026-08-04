# 第 13 章 演習 — 実在する弱点を直す

この章の課題はすべて、`docs/code-overview.md` の「潜在的な改善点」に挙げられた**実在する問題**です。架空の練習問題ではありません。

各課題は「現状 → 何が問題か → 確認方法 → 解答例 → 議論」の順で進みます。**まず自分で解いてから解答例を読んでください。**

作業前に、テストが通る状態から始めることを確認してください。

```sh
stack test
```

---

## 課題 1（高）: `POST /api/sync` の日付を検証する

### 現状

```haskell
-- src/Handler/Api.hs:104
body <- jsonBodyOrEmpty
let field k = DayText <$> (jsonText =<< jsonLookup k body)
    requestedStart = field "start"
    ...
today <- todayUtc
let requestedEnd = fromMaybe today (field "end")
```

リクエストボディの `"start"` / `"end"` を、**検証せずに `DayText` へ包んでいます**。

### 何が問題か

`DayText` は「`YYYY-MM-DD` 形式である」という不変条件を持つはずの型ですが、コンストラクタが公開されているため（第 2 章 2.6）、任意の文字列を包めます。

包まれた値は次の経路をたどります。

```
postSyncR の "end"
  → Sync.runSync
  → findMissingRange（min requestedEnd today: テキスト比較なので通過）
  → syncHeartrateRange
  → addDaysT (-29) windowEnd
  → DateText.parseDay        ← ここで error
```

`parseDay` は失敗時に `error` を投げます（第 4 章 4.5）。**その前提は「ここに届く日付は DB か `formatDay` 由来だから壊れていない」**でしたが、この経路がその前提を破っています。

日次メトリック側は raw SQL の文字列比較にしか使われないため、実害はありません。心拍だけが暦計算を行うので落ちます。

### 確認方法

```sh
# 実 DB を汚さないよう複製に対して起動する
cp oura.db /tmp/oura-test.db
SECRET_KEY=x APP_PASSWORD='<bcrypt hash>' YESOD_SQLITE_DATABASE=/tmp/oura-test.db stack exec oura-dashboard-hs
```

ログイン後、次を送ります。

```sh
curl -X POST localhost:3000/api/sync -H 'Content-Type: application/json' \
     -b cookie.txt -d '{"end":"1999-13-45","metrics":["heartrate"]}'
```

500 が返り、ログに `invalid date: 1999-13-45` が出れば再現です。

### 解答例

**まず落とし穴に注意してください。** `parseDayText` は**形状しか検査しません**。

```haskell
-- src/DateText.hs:49
parseDayText t = case T.splitOn "-" t of
    [y, m, d] | T.length y == 4 && T.length m == 2 && T.length d == 2
              , all (T.all isDigit) [y, m, d] -> Just (DayText t)
    _ -> Nothing
```

`"1999-13-45"` は「4桁-2桁-2桁、全部数字」を満たすので**通ってしまいます**。したがって `parseDayText` を通すだけでは今回のクラッシュは直りません。暦として妥当かの検査が要ります。

GHCi で確認しておきます。

```
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "1999-13-45" :: Maybe Day
Nothing
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "2024-02-30" :: Maybe Day
Nothing
```

`parseTimeM True`（第 1 引数が「空白を許さない厳密モード」）は暦の妥当性まで検査します。これを使った検証関数を `DateText.hs` に追加します。

```haskell
-- src/DateText.hs（export リストに parseDayStrict を追加）

-- | Accept a @YYYY-MM-DD@ string from outside the app, rejecting dates that
-- are well-formed but not real calendar days (@1999-13-45@). Use this at every
-- entry point whose value reaches 'parseDay', which errors on bad input.
parseDayStrict :: Text -> Maybe DayText
parseDayStrict t = do
    _ <- parseDayText t                       -- 形状（区切りと桁数）
    day <- parseTimeM True defaultTimeLocale dayFormat (unpack t) :: Maybe Day
    guard (formatDay day == DayText t)        -- 正規形であることも要求する
    return (DayText t)
```

`guard` を入れているのは、`parseTimeM` が `"2024-1-5"` のような非ゼロ埋め表記も受けうるためです。往復（parse → format）して一致することを求めれば、**DB に入る文字列の形が 1 つに定まります**。これは重要で、日付を文字列比較している以上（第 2 章 2.5）、`"2024-1-5"` が混ざると `Ord` が壊れます。

次に Handler 側です。

```haskell
-- src/Handler/Api.hs

-- | A @YYYY-MM-DD@ field from the request body. Absent is fine; present but
-- invalid is a 400, since these values reach 'parseDay' via the heartrate
-- window arithmetic.
dayField :: Value -> Text -> Handler (Maybe DayText)
dayField body k = case jsonLookup k body of
    Nothing -> return Nothing
    Just v  -> case parseDayStrict =<< jsonText v of
        Just d  -> return (Just d)
        Nothing -> sendStatusJSON status400
            (A.object ["error" A..= ("Invalid date for '" <> k <> "'")])

postSyncR :: Handler Value
postSyncR = do
    requireAuth
    body <- jsonBodyOrEmpty
    requestedStart <- dayField body "start"
    mEnd           <- dayField body "end"
    let requestedMetrics = mapMaybe parseMetricName
                               <$> (jsonArray =<< jsonLookup "metrics" body)
    today <- todayUtc
    let requestedEnd = fromMaybe today mEnd
    ...
```

**「無い」と「不正」を区別している**のが要点です。`parseDayStrict =<< jsonText v` の結果をそのまま `Maybe` として使うと、不正な日付が「指定なし」として静かに無視され、ユーザーは「なぜ指定した範囲が同期されないのか」と悩むことになります。

### テスト

```haskell
-- test/AppSpec.hs の "sync (stub client)" ブロックに追加
it "sync with an invalid end date returns 400" $ do
    login
    request $ do
        setMethod "POST"
        setUrl SyncR
        setRequestBody "{\"end\":\"1999-13-45\"}"
        addRequestHeader ("Content-Type", "application/json")
    statusIs 400

it "sync with a malformed end date returns 400" $ do
    login
    request $ do
        setMethod "POST"
        setUrl SyncR
        setRequestBody "{\"end\":\"not-a-date\"}"
        addRequestHeader ("Content-Type", "application/json")
    statusIs 400
```

第 11 章で見たとおり、`withAppClient (Just syncStubClient)` の下に置けば実 API を叩きません。

### 議論

**より根本的な解決は、`DayText` のコンストラクタを隠すことです。**

```haskell
module DateText
    ( DayText          -- (..) を外す
    , parseDayStrict   -- 唯一の外部入力用構築関数
    , formatDay        -- 唯一の内部構築関数
    , unDayText
    ...
```

こうすれば「検証を通さずに `DayText` を作る」ことが**書けなくなります**。ただし代償があります。

- `IsString` の導出も外すことになり、テストの `"2024-01-31"` というリテラルが全部書き換えになる（`SyncSpec.hs` だけで数十箇所）
- `Db.hs` が SQL 結果から `DayText` を組み立てる経路（`Single d`）にも構築関数が要る

**どちらを取るか**は、このアプリの規模と、外部入力の入口の数で決まります。入口が 3 箇所（`postSyncR` の start/end、`getAdviceEntryR`、`parseRange` のクエリパラメータ）しかないなら、入口で検証する規律の方が安上がりでしょう。

ただし現状は `parseRange` にも同じ穴があります。

```haskell
-- src/Handler/Api.hs:32
paramOr name fallback = maybe fallback DayText <$> lookupGetParam name
```

**追加課題**: `parseRange` も `dayField` と同じ方針で直してください。クエリパラメータの日付は心拍取得（`Db.getHeartrate`）にしか使われず、そこは SQL の文字列比較なので現状クラッシュしません。それでも直すべきでしょうか。「今クラッシュしないから放置」と「入口はすべて検証する」のどちらを選びますか。

---

## 課題 2（中）: 「今日」の基準を統一する

### 現状

```haskell
-- src/DailySync.hs:35
todayJst :: IO DayText
todayJst = todayIn (hoursToTimeZone 9)
```

```haskell
-- src/Handler/Api.hs:27, 109
today <- todayUtc
```

cron は JST、Web は UTC の「今日」を使っています。

### 何が問題か

JST の 0:00〜9:00 の間、両者は 1 日ずれます。例えば JST 2026-08-05 02:00 は UTC 2026-08-04 17:00 なので、

- cron から同期すると「今日 = 2026-08-05」→ 8/5 のデータまで取りに行く
- Web から同期すると「今日 = 2026-08-04」→ 8/4 までしか取りに行かない

さらに `findMissingRange` は `min requestedEnd today` で範囲を打ち切るので、**Web から明示的に `end` を指定しても UTC の今日で切られます**。深夜に「同期したのに今日のデータが来ない」という現象が起きます。

### 確認方法

```haskell
-- GHCi で両者を比較する
stack ghci oura-dashboard-hs:lib
> import DateText
> import Data.Time.LocalTime
> todayUtc
> todayIn (hoursToTimeZone 9)
```

日本時間の深夜に実行すれば差が見えます。差を再現したいなら、`todayIn` に渡すタイムゾーンを変えて確認してください（例: `hoursToTimeZone 14`）。

### 解答例

方針は 2 つあります。

**方針 A: アプリ全体のタイムゾーンを設定にする（推奨）**

```haskell
-- src/Settings.hs の AppSettings に追加
, appTimeZoneHours :: Int
-- ^ Offset from UTC for "today". The Oura API reports days in the user's
-- local calendar, so this must match the ring's time zone.
```

```haskell
-- FromJSON インスタンスに追加
appTimeZoneHours <- o .:? "timezone-hours" .!= 9
```

```yaml
# config/settings.yml に追加
timezone-hours: "_env:TIMEZONE_HOURS:9"
```

```haskell
-- src/DateText.hs に追加（export も）
-- | "Today" in the app's configured time zone.
todayInHours :: MonadIO m => Int -> m DayText
todayInHours h = todayIn (hoursToTimeZone h)
```

呼び出し側:

```haskell
-- src/Handler/Api.hs
appToday :: Handler DayText
appToday = do
    h <- appTimeZoneHours . appSettings <$> getYesod
    todayInHours h
-- parseRange と postSyncR の todayUtc をこれに置き換える
```

```haskell
-- src/DailySync.hs
today <- liftIO $ todayInHours (appTimeZoneHours settings)
```

**方針 B: 単に両方を JST に固定する**

`todayUtc` の呼び出しを `todayIn (hoursToTimeZone 9)` に置き換えるだけ。3 行で終わります。

### 議論

**どちらを選ぶべきか。** 個人用アプリで、リングの持ち主が日本にいて、それが変わる見込みがないなら、方針 B で十分です。設定項目が増えるのはコストです。

一方、方針 A には**設定に意図が書ける**利点があります。「なぜ 9 時間なのか」がコメントとして残る。方針 B だとマジックナンバー `9` がコードに散らばります（せめて `appTimeZone :: TimeZone` のような定数を `DateText.hs` に置くべきでしょう）。

**中間案**として、定数を 1 つ置くだけでも改善です。

```haskell
-- src/DateText.hs
-- | The calendar the app reports days in. The Oura API returns a @day@ per
-- local night, so this must match the ring owner's time zone.
appTimeZone :: TimeZone
appTimeZone = hoursToTimeZone 9

todayLocal :: MonadIO m => m DayText
todayLocal = todayIn appTimeZone
```

**「設定にすべきか定数でよいか」の判断基準**は、「別の値にする人が実際に現れるか」です。現れないなら定数、現れるなら設定。予測が外れても、定数から設定への移行は難しくありません。

---

## 課題 3（中）: アドバイスジョブを回収する

### 現状

```haskell
-- src/Advice.hs:68
type AdviceJobs = TVar (M.Map Text AdviceJob)
```

ジョブを削除する仕組みがありません（第 10 章 10.5）。

### 解答例

完了・失敗から一定時間経ったジョブを捨てます。**まずジョブに時刻を持たせる**必要があります。

```haskell
-- src/Advice.hs
data AdviceJob = AdviceJob
    { jobId       :: Text
    , jobStatus   :: JobStatus
    , jobPeriod   :: A.Value
    , jobAdvice   :: Text
    , jobError    :: Maybe Text
    , jobFinished :: Maybe UTCTime
      -- ^ When the job reached a terminal state; 'Nothing' while it runs.
      -- Used by 'pruneAdviceJobs' to drop old entries.
    }
```

`NominalDiffTime` は ClassyPrelude が re-export していないので、import の追加が要ります（`UTCTime` と `getCurrentTime` は入っています）。第 12 章 12.3 の「入っているか分からなければコンパイラに聞く」の実例です。

```haskell
-- src/Advice.hs の import を変更
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
```

```haskell
-- src/Advice.hs
-- | How long a finished job stays readable by the polling browser.
jobRetention :: NominalDiffTime
jobRetention = 30 * 60   -- 30 minutes

-- | Drop finished jobs older than 'jobRetention'. Called on job creation, so
-- the map cannot grow without bound in a long-running process.
pruneAdviceJobs :: AdviceJobs -> IO ()
pruneAdviceJobs jobs = do
    now <- getCurrentTime
    atomically $ modifyTVar' jobs (M.filter (keep now))
  where
    keep now job = case jobFinished job of
        Nothing       -> True     -- queued or running
        Just finished -> diffUTCTime now finished < jobRetention
```

呼び出しは新規ジョブ作成時にまとめます。

```haskell
createAdviceJob :: AdviceJobs -> A.Value -> IO Text
createAdviceJob jobs period = do
    pruneAdviceJobs jobs
    jid <- UUID.toText <$> UUID.nextRandom
    let job = AdviceJob jid Queued period "" Nothing Nothing
    atomically $ modifyTVar' jobs (M.insert jid job)
    return jid
```

終了時に時刻を記録します。

```haskell
-- runAdviceJob の中
finishJob :: AdviceJobs -> Text -> (AdviceJob -> AdviceJob) -> IO ()
finishJob jobs jid f = do
    now <- getCurrentTime
    setJob jobs jid (\j -> (f j) { jobFinished = Just now })

-- 成功時
finishJob jobs jid (\j -> j { jobStatus = Completed, jobAdvice = adviceOut, jobError = Nothing })

-- 失敗時（fail' の中）
fail' msg = do
    finishJob jobs jid (\j -> j { jobStatus = Failed, jobError = Just msg })
    writeLog appLog LevelError ("advice job " <> jid <> " failed: " <> msg)
```

### 議論

**なぜ「作成時」に掃除するのか。** 専用の掃除スレッド（`forkIO` + `threadDelay` のループ）を立てる方法もありますが、

- スレッドの寿命管理が増える
- ジョブが作られなければメモリは増えないので、掃除も不要

「増える契機で掃除する」のは、**掃除の頻度が増加の頻度に自動的に比例する**良い性質を持ちます。同じ考え方は LRU キャッシュの実装でも使われます。

**保持期間の選び方。** ブラウザがポーリングする間（最大 2 分程度）より十分長く、かつメモリを圧迫しない範囲。30 分は妥当です。ただし**この値の根拠をコメントに書く**こと。「なぜ 30 分か」が分からないと、後から変更してよいか判断できません。

**発展**: 第 10 章 10.4 で述べた `JobState` 型（状態ごとに付随データを持つ ADT）に変更すると、`jobFinished` はどこに置くのが自然でしょうか。`Completed UTCTime Text` / `Failed UTCTime Text` のようにコンストラクタに持たせる案と、レコードに並置する案を比較してください。

---

## 課題 4（低）: `getDailyMetricsBulk` の O(n²) を直す

### 現状

```haskell
-- src/Db.hs:121
let byMetric = M.fromListWith (flip (++))
        [ (metric, [mergeRow day score (parseDataJson dj)])
        | (Single name, Single day, Single score, Single dj) <- rows
        , Just metric <- [parseDailyMetric name] ]
return $ M.union byMetric (M.fromList [ (m, []) | m <- metrics ])
```

第 7 章 7.4 で見たとおり、`flip (++) new old = old ++ new` は毎回 `old` 全体を辿ります。

### 解答例

```haskell
-- 逆順に積んで最後に反転する（O(n)）
let byMetric = M.map reverse $ M.fromListWith (++)
        [ (metric, [mergeRow day score (parseDataJson dj)])
        | (Single name, Single day, Single score, Single dj) <- rows
        , Just metric <- [parseDailyMetric name] ]
return $ M.union byMetric (M.fromList [ (m, []) | m <- metrics ])
```

`fromListWith (++)` は `new ++ old` を計算し、`new` は常に 1 要素なので O(1)。結果は逆順になるので `M.map reverse` で戻します。

**コメントも更新が必要です。** 現在のコメントは `flip (++)` の意図を説明しているので、そのままでは嘘になります。

```haskell
-- The query is ordered by (metric, day). Prepending keeps each append O(1),
-- so the map is built in reverse and flipped back once per metric. Union with
-- the all-metrics map (left-biased) gives metrics without rows an empty list.
```

### 検証

順序が保たれることをテストで固定します。`test/DbSpec.hs` に順序検証がなければ追加してください。

```haskell
it "bulk keeps rows in day order per metric" $ do
    bulk <- runMem $ do
        forM_ ["2024-01-03", "2024-01-01", "2024-01-02"] $ \d ->
            upsertDailyMetric Sleep d (Just 80) (A.object ["day" .= d])
        getDailyMetricsBulk [Sleep] (DateRange "2024-01-01" "2024-01-03")
    let days = mapMaybe (field "day") (M.findWithDefault [] Sleep bulk)
    days `shouldBe` [A.String "2024-01-01", A.String "2024-01-02", A.String "2024-01-03"]
```

### 議論

**この修正は本当に必要か。** 現在の最大呼び出しは `buildHealthPayload` の 14 日分 × 8 メトリック = 112 行。O(n²) と言っても n=14 です。**測定すれば差は出ません。**

それでも直す価値があるのは、

1. 修正が 1 行で、リスクがほぼない
2. 「期間を延ばす」という自然な機能追加で劣化する（アドバイスを 90 日分にしたくなったら？）
3. 同じパターンが `getPaged`（第 7 章）にもあり、**コードベースの規範**として直しておく意味がある

逆に、**もっと大きな n がありうるのに放置されている箇所**を探すのがより重要です。`getHeartrate` は 1 日数百件 × 30 日 = 数千件を返しますが、リスト内包表記で一度に構築しているので O(n) です。問題ありません。

**性能改善の優先順位は「測って決める」が原則**ですが、「ゼロコストで直せるなら直す」も同時に成り立ちます。今回は後者です。

---

## 課題 5（低）: advice ルートの文字列分岐を解消する

### 現状

```haskell
-- src/Handler/Advice.hs:53
getAdviceJobR :: Text -> Handler Value
getAdviceJobR seg = do
    requireAuth
    if seg == "history"
        then adviceHistoryList
        else adviceJobStatus seg
```

### 解答例

`/api/advice/history` を独立したルートにできれば型で分かれます。Yesod は「同じ位置にリテラルと動的セグメント」を許さない、とコメントにありますが、**実際には順序を工夫すれば共存できる場合があります**。まず確かめてください。

```
-- config/routes.yesodroutes（試す）
/api/advice/history/#Text   AdviceEntryR    GET
/api/advice/history         AdviceHistoryR  GET
/api/advice                 AdviceR         POST
/api/advice/#Text           AdviceJobR      GET
```

これがコンパイルを通り、正しくディスパッチされるなら:

```haskell
-- src/Handler/Advice.hs
getAdviceHistoryR :: Handler Value
getAdviceHistoryR = do
    requireAuth
    dates <- runDB Db.getAdviceDates
    returnJson dates

getAdviceJobR :: Text -> Handler Value
getAdviceJobR jid = do
    requireAuth
    adviceJobStatus jid
```

通らない場合は、URL を変える案（`/api/advice/job/#Text`）になりますが、**フロントエンドの変更が必要**です。

```sh
grep -n 'advice' static/api.js static/main.js
```

で影響範囲を確認してください。

### 議論

**URL 契約を変えるかどうか**が判断の分かれ目です。このアプリはフロントエンドを Python 版と共有しているため（`docs/code-overview.md`）、URL を変えると「Python 版の `static/` をそのまま流用できる」という利点を失います。

移植が完了し、Python 版を捨てる決断をした後なら、URL を整理する価値があります。**「いつ技術的負債を返すか」は、その負債を負っている理由が消えたときです。** 理由が生きているうちに返すと、別のコスト（互換性の喪失）を払うことになります。

---

## 課題 6（低）: `Db.hs` に export リストを付ける

### 現状

```haskell
-- src/Db.hs:12
module Db where
```

### 解答例

外部から使われている関数を洗い出します。

```sh
grep -rn 'Db\.' src/ test/ | grep -o 'Db\.[a-zA-Z]*' | sort -u
grep -rn '^import Db' src/ test/
```

`import Db`（非 qualified）しているモジュールがある点に注意してください（`src/Sync.hs:38`、`src/Advice.hs:43`）。その場合、`Db.` の接頭辞なしで使われているので、grep だけでは特定できません。**いったん export リストを最小で書いて、コンパイルエラーで補完する**のが確実です。

```haskell
module Db
    ( -- * Writes
      upsertDailyMetric
    , upsertHeartrateBatch
    , updateSyncLog
    , saveAdvice
      -- * Reads
    , getLastSyncedDay
    , getDailyMetrics
    , getDailyMetricsBulk
    , getHeartrate
    , getAdviceDates
    , getAdviceForDate
    , getSyncStatus
    ) where
```

`nowIso`、`parseDataJson`、`mergeRow` が公開から外れます。テストがそれらを直接使っていれば、テストが壊れます。その場合の選択肢は、

1. テストを公開 API 経由に書き換える（推奨）
2. `-- * Internal, exposed for tests` として明示的に export する

### 議論

**2 番の妥協は許容範囲**です。「テストのために公開している」と書いてあれば、他の場所から使われたときにレビューで気づけます。何も書かずに全公開しているのとは情報量が違います。

なお `Db.hs` を分割する案（`Db/Metrics.hs`、`Db/Advice.hs` など）もありますが、205 行なら分割は不要でしょう。**モジュール分割は行数ではなく「関心事の違い」で決める**べきで、この 205 行は「Python の `db.py` の 1:1 移植」という 1 つの関心事です。

---

## 発展課題

### A. `appOuraClientOverride` を廃止する（第 6 章 6.4）

`Maybe OuraClient` の test seam を `appOuraClient :: OuraClient` に変え、`makeFoundation` で本番クライアントを組み立てる形にしてください。`OURA_TOKEN` 未設定時の挙動（現在は同期時に 500）が変わります。それは改善ですか。

### B. `AdviceJob` の状態を ADT にする（第 10 章 10.4）

`JobStatus` + `jobAdvice` + `jobError` の 3 フィールドを、状態ごとに付随データを持つ 1 つの `JobState` に統合してください。書き換え中にコンパイラが指摘した箇所のうち、実際にバグになりえたものはいくつありましたか。

### C. `runAdviceJob` をテスト可能にする（第 11 章の演習 1）

子プロセス実行を引数に切り出し、4 つの失敗パターンをテストしてください。

### D. 認証ガードの網羅テスト（第 9 章の演習 1）

すべての保護エンドポイントが 401 を返すことを検証してください。ルートを追加したときに自動で検査対象に含める方法はありますか。

### E. ログ言語の統一（`docs/code-overview.md` の最後の項目）

`Advice.runAdviceJob` の失敗メッセージは、ユーザー向け日本語をそのままログにも書いています。ユーザー向け応答と内部ログを分離してください。`fail'` のシグネチャはどう変わりますか。

---

## この教材を終えたあとに

この 13 章で扱ったのは、**2,000 行のアプリを読み書きするために必要な道具**です。実際の現場では、さらに次が必要になります。

- **性能**: プロファイリング（`stack build --profile`）、スペースリークの診断、`Text` / `ByteString` の遅延と正格
- **並行処理の本格活用**: `async` パッケージ、`STM` の合成、ワーカープール
- **エラー処理の設計**: `ExceptT` を使うべき場面、`bracket` によるリソース保証
- **型レベルプログラミング**: `servant` のような型駆動 API 定義、`GADTs`、`DataKinds`
- **ビルドと配布**: Docker、Nix、CI での `stack test`

ただし、これらはすべて**この教材で扱った基礎の上に乗ります**。文字列を型にする、判断を純粋関数に切り出す、依存を値として渡す、失敗の表現を選ぶ——この 4 つができていないコードベースでは、高度な機能を足しても複雑さが増すだけです。

最後に、このプロジェクトから学べる最も実務的な態度を挙げておきます。

**コードに「なぜ」を書く。** このコードベースのコメントは、`-- 何をしているか` ではなく `-- なぜそうしたか` を書いています。

```haskell
-- 'Ord' is the underlying text order, which for this format is chronological
-- Logging must never take the process down
-- Test seam: when set, the sync handler uses this client instead of ...
-- The @catch \@SomeException@ this replaces also swallowed unrelated exceptions
-- the Python assertion expecting only (today, today) was unreachable
```

型は「何を」を語りますが、「なぜ」は語りません。**型が語れない部分をコメントが埋める**——これが、型の強い言語における良いコメントの役割です。
