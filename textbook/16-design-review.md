# 第 16 章 設計を評価する — 既知の弱点の講評

← [第15章 ClassyPrelude・言語拡張・ビルド運用](15-prelude-extensions-build.md) | [目次](README.md) | （なし） →

> **この章に新しい文法はありません。** これまでの 15 章で見た道具を使って、このコードベースに実在する弱点を評価し、直し方を検討します。

良いコードから学べることには限りがあります。**「なぜこうなったのか」「どこまでが許容で、どこからが負債か」**を判断する目は、弱点を具体的に検討することでしか育ちません。

この章で扱う 9 件のうち 8 件は `docs/code-overview.md` の「潜在的な改善点」に挙がっている**実在の問題**です（残る 1 件、16.4 はその 1 項目から発展させた関連問題です）。架空の練習問題ではありません。各項目を「現状 → なぜ問題か → どう直すか → 直すべきか」の順で講評します。

## 目次

- [16.1 高: `POST /api/sync` の日付が検証されていない](#161-高-post-apisync-の日付が検証されていない)
  - [現状](#現状)
  - [なぜ問題か](#なぜ問題か)
  - [どう直すか](#どう直すか)
  - [より根本的な案と、その代償](#より根本的な案とその代償)
- [16.2 中: 「今日」の基準がモジュール間で不一致](#162-中-今日の基準がモジュール間で不一致)
  - [どう直すか](#どう直すか-1)
- [16.3 中: アドバイスジョブが無制限に蓄積する](#163-中-アドバイスジョブが無制限に蓄積する)
  - [どう直すか](#どう直すか-2)
- [16.4 中: `AdviceJob` が不正な状態を表現できる](#164-中-advicejob-が不正な状態を表現できる)
- [16.5 低: `getDailyMetricsBulk` の O(n²)](#165-低-getdailymetricsbulk-の-on²)
- [16.6 低: advice ルートの文字列分岐](#166-低-advice-ルートの文字列分岐)
- [16.7 低: Web 経由の sync だけ backfill が働かない](#167-低-web-経由の-sync-だけ-backfill-が働かない)
- [16.8 低: `Db.hs` に export リストがない](#168-低-dbhs-に-export-リストがない)
- [16.9 低: ログ言語の混在と、テストの穴](#169-低-ログ言語の混在とテストの穴)
- [16.10 このコードベースの評価](#1610-このコードベースの評価)
- [16.11 この教材を終えたあとに](#1611-この教材を終えたあとに)

## 16.1 高: `POST /api/sync` の日付が検証されていない

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

### なぜ問題か

`DayText` は「`YYYY-MM-DD` 形式である」という不変条件を持つはずの型ですが、コンストラクタが公開されているため（第 4 章）任意の文字列を包めます。包まれた値は次の経路をたどります。

```
postSyncR の "end"
  → Sync.runSync
  → findMissingRange（min requestedEnd today: テキスト比較なので通過）
  → syncHeartrateRange
  → addDaysT (-29) windowEnd
  → DateText.parseDay        ← ここで error
```

`parseDay` は失敗時に `error` を投げます（第 7 章）。**その前提は「ここに届く日付は DB か `formatDay` 由来だから壊れていない」**でしたが、この経路がその前提を破っています。`{"end": "1999-13-45", "metrics": ["heartrate"]}` を送ると 500 になります。

日次メトリック側は raw SQL の文字列比較にしか使われないため、実害はありません。**心拍だけが暦計算を行うので落ちる**——このように「経路によって影響が違う」のは、型で守っていない不変条件の典型的な症状です。

### どう直すか

まず落とし穴があります。`parseDayText` は**形状しか検査しません**。

```haskell
-- src/DateText.hs:49
parseDayText t = case T.splitOn "-" t of
    [y, m, d] | T.length y == 4 && T.length m == 2 && T.length d == 2
              , all (T.all isDigit) [y, m, d] -> Just (DayText t)
    _ -> Nothing
```

`"1999-13-45"` は「4桁-2桁-2桁、全部数字」を満たすので**通ってしまいます**。したがって `parseDayText` を挟むだけでは直りません。暦としての妥当性検査が要ります。

GHCi で事実を確認します（第 15 章の習慣）。

```
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "1999-13-45" :: Maybe Day
Nothing
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "2024-02-30" :: Maybe Day
Nothing
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "2024-1-5" :: Maybe Day
Nothing
> parseTimeM True defaultTimeLocale "%Y-%m-%d" "2024-01-05" :: Maybe Day
Just 2024-01-05
```

`parseTimeM` の第 1 引数 `True` は厳密モードで、**暦の妥当性もゼロ埋めも検査する**ことが分かりました。ならば検証関数はこう書けます。

```haskell
-- src/DateText.hs（export リストに追加する）

-- | Accept a @YYYY-MM-DD@ string from outside the app, rejecting dates that
-- are well-formed but not real calendar days (@1999-13-45@). Use this at every
-- entry point whose value reaches 'parseDay', which errors on bad input.
parseDayStrict :: Text -> Maybe DayText
parseDayStrict t = do
    _ <- parseDayText t                                                    -- 形状
    _ <- parseTimeM True defaultTimeLocale dayFormat (unpack t) :: Maybe Day  -- 暦
    return (DayText t)
```

形状検査を残しているのは、`DayText` に入る文字列の形を 1 つに固定するためです（日付を文字列比較している以上、`"2024-1-5"` が混ざると `Ord` が壊れます）。上の GHCi の結果からは厳密モードだけでも弾けると分かりましたが、**2 つの検査が独立に効いている方が、将来 `dayFormat` を変えたときに安全**です。

Handler 側はこうなります。

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
```

**「無い」と「不正」を区別している**のが要点です。`parseDayStrict =<< jsonText v` の結果をそのまま `Maybe` として使うと、不正な日付が「指定なし」として静かに無視され、ユーザーは「なぜ指定した範囲が同期されないのか」と悩むことになります。

テストは第 14 章の `withAppClient (Just syncStubClient)` の下に置けば実 API を叩きません。

```haskell
it "sync with an invalid end date returns 400" $ do
    login
    request $ do
        setMethod "POST"
        setUrl SyncR
        setRequestBody "{\"end\":\"1999-13-45\"}"
        addRequestHeader ("Content-Type", "application/json")
    statusIs 400
```

### より根本的な案と、その代償

`DayText` のコンストラクタを隠せば、「検証を通さずに `DayText` を作る」ことが**書けなくなります**。

```haskell
module DateText
    ( DayText          -- (..) を外す
    , parseDayStrict   -- 唯一の外部入力用構築関数
    , formatDay        -- 唯一の内部構築関数
    , unDayText
    ...
```

ただし代償があります。

- `IsString` の導出も外すことになり、テストの `"2024-01-31"` というリテラルが全部書き換えになる（`SyncSpec.hs` だけで数十箇所）
- `Db.hs` が SQL 結果から `DayText` を組み立てる経路にも構築関数が要る

**どちらを取るかは、外部入力の入口の数で決まります。** 入口が 3 箇所（`postSyncR` の start/end、`getAdviceEntryR`、`parseRange` のクエリパラメータ）しかないなら、入口で検証する規律の方が安上がりでしょう。ただし**その規律が現に破られている**のが今回の問題なので、「規律で守る」を選ぶなら、入口の一覧をコメントかテストで管理する必要があります。

なお `parseRange` にも同じ穴があります。

```haskell
-- src/Handler/Api.hs:32
paramOr name fallback = maybe fallback DayText <$> lookupGetParam name
```

こちらの値は現状 `Db.getHeartrate` の SQL 文字列比較にしか届かないのでクラッシュしません。「今クラッシュしないから放置」か「入口はすべて検証する」か——**私の意見は後者**です。理由は、`parseRange` の値が将来 `addDaysT` に渡らない保証がどこにもないからです。安全性が「呼び出し経路の現状」に依存している状態は、リファクタリングのたびに壊れます。

## 16.2 中: 「今日」の基準がモジュール間で不一致

```haskell
-- src/DailySync.hs:35 — cron は JST
todayJst = todayIn (hoursToTimeZone 9)

-- src/Handler/Api.hs:27, 109 — Web は UTC
today <- todayUtc
```

JST の 0:00〜9:00 の間、両者は 1 日ずれます。JST 2026-08-05 02:00 は UTC 2026-08-04 17:00 なので、

- cron から同期すると「今日 = 2026-08-05」→ 8/5 のデータまで取りに行く
- Web から同期すると「今日 = 2026-08-04」→ 8/4 までしか取りに行かない

さらに `findMissingRange` は `min requestedEnd today` で範囲を打ち切るので、**Web から明示的に `end` を指定しても UTC の今日で切られます**。深夜に「同期したのに今日のデータが来ない」という現象が起きます。

### どう直すか

**案 A: アプリ全体のタイムゾーンを設定にする**

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

**案 B: 定数を 1 つ置いて両方から使う**

```haskell
-- src/DateText.hs
-- | The calendar the app reports days in. The Oura API returns a @day@ per
-- local night, so this must match the ring owner's time zone.
appTimeZone :: TimeZone
appTimeZone = hoursToTimeZone 9

todayLocal :: MonadIO m => m DayText
todayLocal = todayIn appTimeZone
```

**判断**: 個人用アプリで、リングの持ち主が日本にいて、それが変わる見込みがないなら **案 B で十分**です。設定項目が増えるのはコストであり、「設定できる」こと自体は価値ではありません。

ただし案 B でも、`todayUtc` の呼び出しを機械的に `todayIn (hoursToTimeZone 9)` に置換するのは避けてください。マジックナンバー `9` がコードに散らばります。**名前とコメントが付いた定数を 1 つ作り、そこに理由を書く**のが最小の正解です。

**「設定にすべきか定数でよいか」の判断基準**は「別の値にする人が実際に現れるか」。現れないなら定数、現れるなら設定。予測が外れても、定数から設定への移行は難しくありません。

## 16.3 中: アドバイスジョブが無制限に蓄積する

第 13 章で見たとおり、`TVar (Map Text AdviceJob)` から完了ジョブを回収する仕組みがありません。

### どう直すか

ジョブに終了時刻を持たせ、作成時に古いものを掃除します。

```haskell
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

```haskell
-- | How long a finished job stays readable by the polling browser.
-- The browser polls for at most a couple of minutes; 30 minutes leaves room
-- for a reload without letting the map grow unbounded.
jobRetention :: NominalDiffTime
jobRetention = 30 * 60

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

**なぜ「作成時」に掃除するのか。** 専用の掃除スレッド（`forkIO` + `threadDelay` のループ）を立てる方法もありますが、

- スレッドの寿命管理が増える（第 13 章の「管理されていないスレッド」を 1 つ増やすことになる）
- ジョブが作られなければメモリは増えないので、掃除も不要

「増える契機で掃除する」は、**掃除の頻度が増加の頻度に自動的に比例する**良い性質を持ちます。同じ考え方は LRU キャッシュの実装でも使われます。

**保持期間の根拠はコメントに書くこと。** 「なぜ 30 分か」が分からないと、後から変更してよいか判断できません。

なお `NominalDiffTime` は ClassyPrelude が re-export していないので import の追加が要ります（`UTCTime` と `getCurrentTime` は入っています）。第 15 章の「入っているか分からなければコンパイラに聞く」の実例です。

## 16.4 中: `AdviceJob` が不正な状態を表現できる

第 13 章 13.4 で見たとおり、`jobStatus` と `jobAdvice` / `jobError` が独立しているため、「完了なのに本文が空」「失敗なのにエラーメッセージが無い」が表現できます。

```haskell
data JobState
    = Queued
    | Running
    | Completed Text        -- アドバイス本文
    | Failed Text           -- エラーメッセージ
```

に統合すれば、不正な組み合わせが**書けなくなります**。16.3 の `jobFinished` も、`Completed UTCTime Text` / `Failed UTCTime Text` としてコンストラクタに載せる案と、レコードに並置する案があります。

**私の推奨は後者（レコードに並置）**です。理由は、`jobFinished` が「終了したかどうか」ではなく「いつ終わったか」という直交する情報であり、コンストラクタに載せると `pruneAdviceJobs` が状態ごとにパターンマッチすることになるからです。**ADT のコンストラクタに載せるべきは、その状態でだけ意味を持つデータ**です。

この修正の副作用として、`Handler/Advice.hs` と `test/AppSpec.hs:215`（`insertJob`）が書き換えになります。**型を締めるとコンパイラが影響範囲を全部教えてくれる**ので、作業自体は機械的です。第 3 章で見た「型を変えるとコンパイラが指摘する」の実践例になります。

## 16.5 低: `getDailyMetricsBulk` の O(n²)

第 9 章で見たとおり、`M.fromListWith (flip (++))` は `old ++ new` を毎回計算します。

```haskell
-- 現状（src/Db.hs:121）
let byMetric = M.fromListWith (flip (++)) [ ... ]

-- 改善（O(n)）
let byMetric = M.map reverse $ M.fromListWith (++) [ ... ]
```

**コメントの更新も必要です。** 現在のコメントは `flip (++)` の意図を説明しているので、直すと嘘になります。

```haskell
-- The query is ordered by (metric, day). Prepending keeps each append O(1),
-- so the map is built in reverse and flipped back once per metric. Union with
-- the all-metrics map (left-biased) gives metrics without rows an empty list.
```

**この修正は本当に必要か。** 現在の最大呼び出しは `buildHealthPayload` の 14 日分 × 8 メトリック = 112 行です。n=14 では測っても差は出ません。それでも直す価値があるのは、

1. 修正が 1 行で、リスクがほぼない
2. 「期間を延ばす」という自然な機能追加で劣化する（アドバイスを 90 日分にしたくなったら？）
3. 同じパターンが `getPaged`（第 9 章）にもあり、**コードベースの規範**として直しておく意味がある

**性能改善の優先順位は「測って決める」が原則**ですが、「ゼロコストで直せるなら直す」も同時に成り立ちます。今回は後者です。

逆に、**もっと大きな n がありうるのに放置されている箇所**を探す方が重要です。`getHeartrate` は 1 日数百件 × 30 日 = 数千件を返しますが、リスト内包表記で一度に構築しているので O(n)。問題ありません。

## 16.6 低: advice ルートの文字列分岐

```haskell
-- src/Handler/Advice.hs:53
getAdviceJobR seg = do
    requireAuth
    if seg == "history"
        then adviceHistoryList
        else adviceJobStatus seg
```

第 12 章で見たとおり、型安全ルーティングの外に出ています。ルート定義を分けられれば型で分かれます。

```
-- config/routes.yesodroutes（検証が必要）
/api/advice/history/#Text   AdviceEntryR    GET
/api/advice/history         AdviceHistoryR  GET
/api/advice                 AdviceR         POST
/api/advice/#Text           AdviceJobR      GET
```

**判断が分かれるのは URL 契約を変えるかどうか**です。このアプリはフロントエンド（`static/*.js`）を Python 版と共有しているため、URL を変えると「Python 版の `static/` をそのまま流用できる」という利点を失います。

> **「いつ技術的負債を返すか」は、その負債を負っている理由が消えたときです。** 理由が生きているうちに返すと、別のコスト（互換性の喪失）を払うことになります。

移植が完了し Python 版を捨てる決断をした後なら、URL を整理する価値があります。それまでは、**コメントで理由を残してある現状が正しい**と評価します。

## 16.7 低: Web 経由の sync だけ backfill が働かない

```haskell
-- src/Handler/Api.hs:120
result <- runDB $ Sync.runSync today client requestedStart (Just requestedEnd) requestedMetrics 0
                                                                                              -- ↑ backfillDays = 0 固定
```

```haskell
-- src/DailySync.hs:32
backfillDays :: Int
backfillDays = 7
```

cron は 7 日分の欠損を埋めますが、Web からの同期は増分だけです。おそらく「Web からの同期は速く返したい」という意図でしょうが、**コードにその意図が書かれていません**。

**この種の「非対称なマジックナンバー」は、コメント 1 行で解決します。**

```haskell
-- Backfill is the cron job's responsibility; a browser-triggered sync should
-- return promptly, so it only fetches the incremental range.
result <- runDB $ Sync.runSync today client requestedStart (Just requestedEnd) requestedMetrics 0
```

修正コストはほぼゼロで、「Web から同期したのに古い欠損が埋まらない」という将来の混乱を防げます。**評価: 直すべき。**（もし意図がそうでないなら、それはバグなので、いずれにせよ意図を明示する必要があります。）

## 16.8 低: `Db.hs` に export リストがない

```haskell
-- src/Db.hs:12
module Db where
```

第 1 章で述べたとおり、内部ヘルパー（`nowIso`、`parseDataJson`、`mergeRow`）まで公開されています。

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

作業の注意点として、`import Db`（非 qualified）しているモジュールがあります（`src/Sync.hs:38`、`src/Advice.hs:43`）。`Db.` の接頭辞なしで使われているため grep だけでは特定できません。**いったん最小の export リストを書いて、コンパイルエラーで補完する**のが確実です。

テストが内部関数を直接使っている場合の選択肢は 2 つ。

1. テストを公開 API 経由に書き換える（推奨）
2. `-- * Internal, exposed for tests` として明示的に export する

**2 番の妥協も許容範囲**です。「テストのために公開している」と書いてあれば、他の場所から使われたときにレビューで気づけます。何も書かずに全公開しているのとは情報量が違います。

なお `Db.hs` を分割する案（`Db/Metrics.hs`、`Db/Advice.hs`）もありますが、205 行なら不要でしょう。**モジュール分割は行数ではなく「関心事の違い」で決める**べきで、この 205 行は「Python の `db.py` の 1:1 移植」という 1 つの関心事です。

## 16.9 低: ログ言語の混在と、テストの穴

**ログ言語**: `Advice.runAdviceJob` の失敗メッセージは、ユーザー向けの日本語をそのままログにも書いています。

```haskell
fail' "分析がタイムアウトしました。"
```

`fail'` はジョブ状態（ユーザーに返る）とログの両方に同じ文字列を使います。他のログ行は英語なので、ログを追うときに言語が混在します。**ユーザー向け応答と内部ログは別物**として、`fail' userMsg logMsg` のように分離するのが素直です。

**テストの穴**: 第 14 章で挙げたとおり、認証ガードの網羅テストがありません。ルートを追加したときに自動で検査対象に入れるには、保護対象ルートのリストを 1 箇所に持ち、テストがそれを走査する形にします。

```haskell
protectedRoutes :: [Route App]
protectedRoutes = [MetricsR, MetricR "sleep", HeartrateR, SyncStatusR, ...]
```

ただし `Route App` は「引数を取るルート」があるため `[minBound .. maxBound]` のような全列挙はできません（`Enum` を導出できない）。**フレームワークの型安全は「存在するルートしか書けない」までを保証し、「全ルートを列挙する」は保証しない**——守備範囲の理解が、テスト設計にも効いてきます。

**test seam の廃止**（第 10 章の `appOuraClientOverride`）も、この列にあります。`appOuraClient :: OuraClient` を常に持つ設計にすると、`OURA_TOKEN` 未設定時の挙動が「同期時に 500」から「起動時に決まる」へ変わります。設定不備は起動時に落とす方が良い（第 7 章）という原則からは、こちらが改善です。

## 16.10 このコードベースの評価

弱点を 9 件並べましたが、**全体としては良く書かれたコードベースです。** 評価すべき点を挙げます。

- 文字列の型化（第 3・4 章）が徹底されており、分岐の網羅性がコンパイラに委ねられている
- ドメイン層が Web フレームワークに依存せず、Web と cron の両方から使える（第 1・8 章）
- 判断が純粋関数に切り出され、テストが軽い（第 6・14 章）
- 外部依存が値として注入され、スタブ差し替えが容易（第 10 章）
- **型安全機構を外した箇所には、理由がコメントで書かれている**（raw SQL、文字列ルーティング、`error` の前提）

そして最後の項目が、このコードベースから学べる最も実務的な態度です。

**コードに「なぜ」を書く。** このコードベースのコメントは、`-- 何をしているか` ではなく `-- なぜそうしたか` を書いています。

```haskell
-- 'Ord' is the underlying text order, which for this format is chronological
-- Logging must never take the process down
-- Test seam: when set, the sync handler uses this client instead of ...
-- The @catch \@SomeException@ this replaces also swallowed unrelated exceptions
-- the Python assertion expecting only (today, today) was unreachable
```

**型は「何を」を語りますが、「なぜ」は語りません。型が語れない部分をコメントが埋める**——これが、型の強い言語における良いコメントの役割です。

## 16.11 この教材を終えたあとに

この 16 章で扱ったのは、**2,000 行のアプリを読み書きするために必要な文法と設計**です。現場ではさらに次が必要になります。

- **性能**: プロファイリング（`stack build --profile`）、スペースリークの診断、`Text` / `ByteString` の遅延と正格
- **並行処理の本格活用**: `async` パッケージ、STM の合成、ワーカープール
- **エラー処理の設計**: `ExceptT` を使うべき場面、`bracket` によるリソース保証
- **型レベルプログラミング**: `servant` のような型駆動 API 定義、`GADTs`、`DataKinds`
- **ビルドと配布**: Docker、Nix、CI での `stack test`

ただし、これらはすべて**この教材で扱った基礎の上に乗ります**。文字列を型にする、判断を純粋関数に切り出す、依存を値として渡す、失敗の表現を選ぶ——この 4 つができていないコードベースでは、高度な機能を足しても複雑さが増すだけです。

最後に、レビューの手順として使えるチェックリストを置いておきます。

| 観点 | 問い | 本書の章 |
|---|---|---|
| 型 | 文字列で分岐している箇所はないか | 3 |
| 型 | 同じ `Text` で意味が違うものが混ざっていないか | 4 |
| 型 | 不正な状態が表現できてしまっていないか | 13 |
| 純粋性 | 判断ロジックが IO の中に埋まっていないか | 6 |
| 純粋性 | 現在時刻・乱数・外部クライアントが注入されているか | 6, 10 |
| 失敗 | `SomeException` を捕まえていないか | 7 |
| 失敗 | `error` の前提（入口の検証）が実際に守られているか | 7, 16 |
| 制約 | 関数の制約が必要最小限か（`IO` 固定になっていないか） | 8 |
| 性能 | `++` の繰り返しや遅延の蓄積がないか | 9 |
| 境界 | 型安全機構を外した箇所に理由と代替の防御があるか | 12 |
| テスト | 型で守れない部分がテストで守られているか | 14 |
| テスト | 「テストされていないもの」を把握しているか | 14 |

---

← [第15章 ClassyPrelude・言語拡張・ビルド運用](15-prelude-extensions-build.md) | [目次](README.md) | （なし） →
