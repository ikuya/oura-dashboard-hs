{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Advice job logic, ported from app.py.
--
-- Jobs live in an in-process 'TVar' map (mirroring the Lock-guarded _advice_jobs
-- dict) and run in a 'forkIO' worker that shells out to the @claude@ CLI. Jobs
-- are non-persistent: they vanish on restart, exactly like the Python app.
module Advice
    ( AdviceJob (..)
    , JobStatus (..)
    , statusText
    , AdviceJobs
    , adviceSystemPrompt
    , extractKeyFields
    , adviceDays
    , advicePeriod
    , buildHealthPayload
    , buildAdvicePrompt
    , adviceComparison
    , hasHealthData
    , generateAdvice
    , newAdviceJobs
    , createAdviceJob
    , getJob
    , runAdviceJob
    ) where

import ClassyPrelude hiding (timeout)
import qualified Data.Aeson          as A
import qualified Data.Aeson.Encode.Pretty as AP
import qualified Data.Aeson.Key      as K
import qualified Data.Aeson.KeyMap   as KM
import qualified Data.Map.Strict     as M
import qualified Data.Text.Lazy      as TL
import Database.Persist.Sql       (SqlBackend)
import System.Exit                (ExitCode (..))
import System.IO.Error            (isDoesNotExistError)
import System.Process             (readCreateProcessWithExitCode, proc)
import System.Timeout             (timeout)
import qualified Data.UUID         as UUID
import qualified Data.UUID.V4      as UUID
import Control.Monad.Logger       (LogLevel (..))
import Data.Time.Clock            (diffUTCTime)
import Data.Time.Format.ISO8601   (iso8601ParseM)
import Data.Time.LocalTime        (addLocalTime, zonedTimeToLocalTime,
                                   zonedTimeToUTC)

import DateText                   (DateRange (..), DayText (..), addDaysT)
import Db
import Json                       (jsonDouble, jsonText, jsonLookup)
import Metric                     (DailyMetric (..), EventKind (..),
                                   allEventKinds, dailyMetricName,
                                   dashboardMetrics, eventKindName)
import Logging                    (AppLog (..))

-- | Job lifecycle states.
data JobStatus = Queued | Running | Completed | Failed
    deriving (Eq, Show)

statusText :: JobStatus -> Text
statusText Queued    = "queued"
statusText Running   = "running"
statusText Completed = "completed"
statusText Failed    = "failed"

-- | A single advice job. @period@ is the {start,end,days} object and
-- @comparison@ the 'adviceComparison' shown above the finished report.
data AdviceJob = AdviceJob
    { jobId         :: Text
    , jobStatus     :: JobStatus
    , jobPeriod     :: A.Value
    , jobComparison :: A.Value
    , jobAdvice     :: Text
    , jobError      :: Maybe Text
    }

type AdviceJobs = TVar (M.Map Text AdviceJob)

-- | The system prompt. With a previous advice to follow on from, the report
-- gains a section on what changed since then.
adviceSystemPrompt :: Maybe SavedAdvice -> Text
adviceSystemPrompt previous = intercalate "\n" $
    [ "あなたはOura Ringの健康データを解析する専門家アシスタントです。"
    , "ユーザーから過去14日間のOura Ringデータ（睡眠、準備度、活動量、ストレス、血中酸素濃度、体温偏差、回復力、VO2 Max、心血管年齢）が提供されます。"
    , "`sleep_periods` は各日の睡眠段階の実時間（秒）です。同じ日の本睡と仮眠を合算しています。"
    , "`bedtime_start`（就床）・`sleep_onset`（入眠）・`bedtime_end`（起床）はその日の本睡の時刻（記録地の時刻、HH:MM）です。`naps` は仮眠の回数、`nap_time_in_bed` はその合計時間（秒）です。"
    , "`average_hrv`（夜間平均HRV、ms）・`lowest_heart_rate`（最低心拍、bpm）・`average_heart_rate`（平均心拍、bpm）・`average_breath`（平均呼吸数、回/分）もその日の本睡の値です。"
    , "`tags` はユーザーが Oura アプリで付けたタグ（`tag` は種類のコードまたは自由入力名、例: `tag_sleep_alcohol` は飲酒）、`workouts` はワークアウト（`minutes` は時間、`start` は開始時刻）、`sessions` は瞑想・休息などのセッションです。日付 D のタグやワークアウトはその夜の睡眠（D+1 の `sleep_periods`・`sleep`）と翌朝の準備度（D+1 の `readiness`）に影響しうるので、該当があれば関連を具体的に指摘してください。"
    ]
    ++ whenPrevious
    [ "データの後の `<previous_advice>` には前回のアドバイスが入っています。前回の保存日より後の日を中心に、前回指摘した点や提案がその後どうなったかをデータから評価してください。改善が見られない提案は同じ文言で繰り返さず、別の切り口を示してください。" ]
    ++
    [ ""
    , "## 役割"
    , "1. データを客観的に分析し、現在の健康状態を簡潔に要約する"
    , "2. トレンドや注目すべき変化点を特定する"
    , "3. 実践的かつ具体的なアドバイスを提供する"
    , ""
    , "## 出力フォーマット"
    , "以下の構成で回答してください："
    , ""
    , "### 📊 現在の健康状態"
    , "（各メトリクスの直近の数値とトレンドを2〜3文でまとめる）"
    , ""
    ]
    ++ whenPrevious
    [ "### 🔁 前回からの変化"
    , "（前回のアドバイス以降に改善・悪化した点と、前回の提案の効果が見られるかを2〜4項目の箇条書きで評価する）"
    , ""
    ]
    ++
    [ "### ⚠️ 注目ポイント"
    , "（気になる変化・改善が必要な項目を箇条書きで列挙。良い場合は「特になし」と記載）"
    , ""
    , "### 💡 アドバイス"
    , "（データに基づいた具体的な行動提案を3〜5項目の箇条書きで記載）"
    , ""
    , "---"
    , "- すべての回答は日本語で行うこと"
    , "- スコアの良し悪しの判断基準：80以上=良好（緑）、60〜79=普通（黄）、60未満=要注意（赤）"
    , "- 体温偏差は±0.5°C以内が正常範囲"
    , "- 医療的な診断は行わないこと"
    , ""
    ]
  where
    whenPrevious ls = if isJust previous then ls else []

appendSystemPrompt :: String
appendSystemPrompt =
    "You are a health data analysis assistant. Output only the analysis report. No preamble, no self-explanation, no meta-commentary about the task."

-- | Extract the key fields from a metric row for the advice payload.
extractKeyFields :: DailyMetric -> A.Value -> A.Value
extractKeyFields metric row =
    let g k = fromMaybe A.Null (jsonLookup k row)
        base = [("day", g "day"), ("score", g "score")]
        extra = case metric of
            Sleep       -> [("contributors", g "contributors")]
            Readiness   -> [("contributors", g "contributors")]
            Activity    ->
                [ ("active_calories", g "active_calories"), ("steps", g "steps")
                , ("high_activity_time", g "high_activity_time")
                , ("medium_activity_time", g "medium_activity_time")
                , ("low_activity_time", g "low_activity_time")
                , ("sedentary_time", g "sedentary_time")
                , ("inactivity_alerts", g "inactivity_alerts") ]
            Stress      ->
                [ ("stress_high", g "stress_high"), ("recovery_high", g "recovery_high")
                , ("day_summary", g "day_summary") ]
            Spo2        -> [("spo2_percentage", g "spo2_percentage")]
            Temperature ->
                [ ("temperature_deviation", g "temperature_deviation")
                , ("temperature_trend_deviation", g "temperature_trend_deviation") ]
            Resilience        -> [("level", g "level")]
            CardiovascularAge -> [("vascular_age", g "vascular_age")]
            VO2Max            -> []
    in A.Object (KM.fromList (base ++ extra))

-- | The stage durations of a sleep period, in seconds.
sleepDurationFields :: [Text]
sleepDurationFields =
    [ "deep_sleep_duration", "light_sleep_duration", "rem_sleep_duration"
    , "awake_time", "total_sleep_duration", "time_in_bed" ]

-- | One row per day, summing the stage durations of that day's periods. A day
-- can hold several (a long sleep plus naps) and the prompt wants the night as
-- a whole. The 5-minute phase timeline is deliberately left out: the charts
-- read it, but as prompt text it is thousands of tokens the model cannot use.
--
-- The bedtime / onset / wake clock times come from the main period alone, and
-- the other periods are reported as naps, the same split the Bedtime / Wake
-- chart draws.
sleepStageTotals :: [A.Value] -> [A.Value]
sleepStageTotals periods =
    [ A.Object $ KM.fromList $ ("day", A.toJSON day)
        : [ (K.fromText f, A.toJSON (sum (map (periodSeconds f) rows)))
          | f <- sleepDurationFields ]
        ++ sleepTimes rows
    | (day, rows) <- M.toAscList byDay ]
  where
    byDay = M.fromListWith (flip (++))
        [ (day, [r])
        | r <- periods, Just day <- [jsonText =<< jsonLookup "day" r] ]

-- | The main period's clock times and vitals, plus the nap count and their
-- time in bed. The vitals are the main period's alone: a nap's HRV or lowest
-- heart rate is not comparable with a night's.
sleepTimes :: [A.Value] -> [(A.Key, A.Value)]
sleepTimes rows =
    [ ("bedtime_start", A.toJSON (clockAt 0 =<< start))
    , ("sleep_onset",   A.toJSON (clockAt latency =<< start))
    , ("bedtime_end",   A.toJSON (clockAt 0 =<< str "bedtime_end"))
    , ("naps",            A.toJSON (length naps))
    , ("nap_time_in_bed", A.toJSON (sum (map (periodSeconds "time_in_bed") naps)))
    ]
    ++ [ (K.fromText f, fromMaybe A.Null (jsonLookup f =<< primary))
       | f <- sleepVitalFields ]
  where
    primary = mainSleepPeriod rows
    naps = filter ((/= primary) . Just) rows
    str k = jsonText =<< jsonLookup k =<< primary
    start = str "bedtime_start"
    latency = maybe 0 (periodSeconds "latency") primary

-- | Per-night vitals of a sleep period. The 5-minute series behind them stay
-- out of the prompt for the same reason the phase timeline does.
sleepVitalFields :: [Text]
sleepVitalFields =
    ["average_hrv", "lowest_heart_rate", "average_heart_rate", "average_breath"]

-- | "HH:MM" on the wall clock where the period was recorded, @offset@ seconds
-- after the given ISO 8601 timestamp. The timestamp's own UTC offset is kept
-- rather than converting to the server's zone, so a night abroad reads as the
-- local time it was slept.
clockAt :: Int -> Text -> Maybe Text
clockAt offset ts =
    pack . formatTime defaultTimeLocale "%H:%M"
         . addLocalTime (fromIntegral offset) . zonedTimeToLocalTime
        <$> iso8601ParseM (unpack ts)

-- | The fields of a tag, workout or session the prompt needs. Clock times are
-- local "HH:MM" like the sleep times, and a duration is in whole minutes.
eventSummary :: EventKind -> A.Value -> A.Value
eventSummary kind r = A.object $ case kind of
    Tags ->
        [ "day"     A..= g "start_day"
        , "end_day" A..= g "end_day"
        , "tag"     A..= (jsonLookup "custom_name" r <|> jsonLookup "tag_type_code" r)
        , "time"    A..= (clockAt 0 =<< str "start_time")
        , "comment" A..= g "comment" ]
    Workouts ->
        [ "day"       A..= g "day"
        , "activity"  A..= g "activity"
        , "intensity" A..= g "intensity"
        , "start"     A..= (clockAt 0 =<< str "start_datetime")
        , "minutes"   A..= minutes
        , "calories"  A..= (round <$> (jsonDouble =<< jsonLookup "calories" r) :: Maybe Int) ]
    Sessions ->
        [ "day"     A..= g "day"
        , "type"    A..= g "type"
        , "start"   A..= (clockAt 0 =<< str "start_datetime")
        , "minutes" A..= minutes
        , "mood"    A..= g "mood" ]
  where
    g k = fromMaybe A.Null (jsonLookup k r)
    str k = jsonText =<< jsonLookup k r
    instant t = zonedTimeToUTC <$> iso8601ParseM (unpack t)
    minutes :: Maybe Int
    minutes = do
        from <- instant =<< str "start_datetime"
        to   <- instant =<< str "end_datetime"
        return (round (diffUTCTime to from / 60))

-- | How many days an advice analyses.
adviceDays :: Int
adviceDays = 14

-- | The 'adviceDays' ending on the given day.
advicePeriod :: DayText -> DateRange
advicePeriod today =
    DateRange (addDaysT (negate (fromIntegral adviceDays - 1)) today) today

-- | Build the health payload over 'advicePeriod' (period + per-metric key
-- fields).
buildHealthPayload :: (MonadIO m) => DayText -> ReaderT SqlBackend m A.Value
buildHealthPayload today = do
    let range@(DateRange start _) = advicePeriod today
    bulk <- getDailyMetricsBulk dashboardMetrics range
    sleepPeriods <- getSleepPeriods range
    events <- forM allEventKinds $ \k ->
        (K.fromText (eventKindName k) A..=) . map (eventSummary k) <$> getEvents k range
    let metricsObj = KM.fromList
            [ ( K.fromText (dailyMetricName m)
              , A.toJSON (map (extractKeyFields m) (M.findWithDefault [] m bulk)) )
            | m <- dashboardMetrics ]
        period = A.object ["start" A..= start, "end" A..= today, "days" A..= adviceDays]
    return $ A.object $
        [ "period"        A..= period
        , "metrics"       A..= A.Object metricsObj
        , "sleep_periods" A..= sleepStageTotals sleepPeriods
        ] ++ events

-- | Build the prompt string: the system prompt, the JSON code block, and the
-- previous advice (if any) for the report to follow on from.
buildAdvicePrompt :: Maybe SavedAdvice -> A.Value -> Text
buildAdvicePrompt previous healthData =
    adviceSystemPrompt previous <> "\n\n```json\n" <> prettyJson <> "\n```"
        <> foldMap previousBlock previous
  where
    previousBlock p =
        let DateRange start end = savedAdvicePeriod p
        in "\n\n<previous_advice saved_at=\"" <> savedAdviceAt p
            <> "\" period=\"" <> unDayText start <> ".." <> unDayText end <> "\">\n"
            <> savedAdviceContent p <> "\n</previous_advice>"
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }

-- | The scores headlined over an advice report.
comparisonMetrics :: [DailyMetric]
comparisonMetrics = [Readiness, Sleep, Activity]

-- | Each headline score's mean over the advice's period beside its mean over
-- the previous advice's period, so the report shows how far things moved
-- since then. Without a previous advice the @previous@ means are null.
adviceComparison
    :: (MonadIO m)
    => DateRange -> Maybe SavedAdvice -> ReaderT SqlBackend m A.Value
adviceComparison range previous = do
    current <- getScoreAverages comparisonMetrics range
    before <- maybe (pure M.empty) (getScoreAverages comparisonMetrics . savedAdvicePeriod) previous
    return $ A.object
        [ "previous" A..= fmap previousJson previous
        , "scores" A..=
            [ A.object
                [ "metric"   A..= dailyMetricName m
                , "average"  A..= M.lookup m current
                , "previous" A..= M.lookup m before ]
            | m <- comparisonMetrics ]
        ]
  where
    previousJson p =
        let DateRange start end = savedAdvicePeriod p
        in A.object
            [ "saved_at" A..= savedAdviceAt p
            , "period"   A..= A.object ["start" A..= start, "end" A..= end] ]

-- | Whether the payload holds any metric rows at all. With none there is
-- nothing to analyse, and asking anyway only spends a claude call.
hasHealthData :: A.Value -> Bool
hasHealthData healthData = case jsonLookup "metrics" healthData of
    Just (A.Object ms) -> any nonEmptyArr (KM.elems ms)
    _                  -> False
  where
    nonEmptyArr (A.Array a) = not (null a)
    nonEmptyArr _           = False

-- | Run the claude CLI on a prompt: the report, or why it could not be had.
-- Shared by the web's advice jobs and the scheduled CLI.
generateAdvice :: Text -> IO (Either Text Text)
generateAdvice prompt = do
    let cp = proc "claude"
            [ "-p", unpack prompt, "--max-turns", "1", "--model", "opus"
            , "--append-system-prompt", appendSystemPrompt ]
    result <- try (timeout (120 * 1000000) (readCreateProcessWithExitCode cp ""))
    return $ case result of
        Left (e :: IOException)
            | isDoesNotExistError e ->
                Left "claude コマンドが見つかりません。Claude Code がインストールされているか確認してください。"
            | otherwise ->
                Left ("Claude Code の実行に失敗しました: " <> tshow e)
        Right Nothing ->
            Left "分析がタイムアウトしました。"
        Right (Just (ExitFailure _, out, err)) ->
            Left (if null err
                      then if null out
                               then "Claude Code の実行に失敗しました。"
                               else "Claude Code の実行に失敗しました: " <> pack out
                      else pack err)
        Right (Just (ExitSuccess, out, _)) ->
            Right (pack out)

-- TVar job map -----------------------------------------------------------

newAdviceJobs :: IO AdviceJobs
newAdviceJobs = newTVarIO M.empty

-- | Create a queued job with a fresh UUID and return its id.
createAdviceJob :: AdviceJobs -> A.Value -> A.Value -> IO Text
createAdviceJob jobs period comparison = do
    jid <- UUID.toText <$> UUID.nextRandom
    let job = AdviceJob jid Queued period comparison "" Nothing
    atomically $ modifyTVar' jobs (M.insert jid job)
    return jid

getJob :: AdviceJobs -> Text -> IO (Maybe AdviceJob)
getJob jobs jid = M.lookup jid <$> readTVarIO jobs

setJob :: AdviceJobs -> Text -> (AdviceJob -> AdviceJob) -> IO ()
setJob jobs jid f = atomically $ modifyTVar' jobs (M.adjust f jid)

-- | Worker: run the claude CLI, update job state, and save advice on success.
-- @saveOnSuccess@ persists the advice to advice_history (period start/end).
runAdviceJob
    :: AppLog
    -> AdviceJobs
    -> Text                                   -- ^ job id
    -> Text                                   -- ^ prompt
    -> (DayText -> DayText -> Text -> IO ())  -- ^ save action: start end content
    -> IO ()
runAdviceJob appLog jobs jid prompt saveAdvice' = do
    setJob jobs jid (\j -> j { jobStatus = Running })
    writeLog appLog LevelInfo ("advice job " <> jid <> " started")
    started <- getCurrentTime
    result <- generateAdvice prompt
    case result of
        Left msg -> fail' msg
        Right adviceOut -> do
            setJob jobs jid (\j -> j { jobStatus = Completed, jobAdvice = adviceOut, jobError = Nothing })
            elapsed <- elapsedSince started
            writeLog appLog LevelInfo
                ("advice job " <> jid <> " completed in " <> elapsed)
            -- Save to advice_history using the job's period.
            mjob <- getJob jobs jid
            case mjob >>= periodBounds . jobPeriod of
                Just (start, end) -> saveAdvice' start end adviceOut
                Nothing           -> return ()
  where
    -- The job state is only kept in a TVar, so without this a failed job is
    -- invisible outside the browser session that polled for it.
    fail' msg = do
        setJob jobs jid (\j -> j { jobStatus = Failed, jobError = Just msg })
        writeLog appLog LevelError ("advice job " <> jid <> " failed: " <> msg)

    elapsedSince t0 = do
        now <- getCurrentTime
        return (tshow (diffUTCTime now t0))
    periodBounds v = (,) <$> field "start" <*> field "end"
      where
        field k = DayText <$> (jsonText =<< jsonLookup k v)
