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
    , buildHealthPayload
    , buildAdvicePrompt
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
import System.Process             (readCreateProcessWithExitCode, proc)
import System.Timeout             (timeout)
import qualified Data.UUID         as UUID
import qualified Data.UUID.V4      as UUID
import Control.Monad.Logger       (LogLevel (..))
import Data.Time.Clock            (diffUTCTime)
import Data.Time.Format.ISO8601   (iso8601ParseM)
import Data.Time.LocalTime        (addLocalTime, zonedTimeToLocalTime)

import DateText                   (DateRange (..), DayText (..), addDaysT)
import Db
import Json                       (jsonInt, jsonText, jsonLookup)
import Metric                     (DailyMetric (..), dailyMetricName,
                                   dashboardMetrics)
import Logging                    (AppLog (..))

-- | Job lifecycle states.
data JobStatus = Queued | Running | Completed | Failed
    deriving (Eq, Show)

statusText :: JobStatus -> Text
statusText Queued    = "queued"
statusText Running   = "running"
statusText Completed = "completed"
statusText Failed    = "failed"

-- | A single advice job. @period@ is the {start,end,days} object.
data AdviceJob = AdviceJob
    { jobId     :: Text
    , jobStatus :: JobStatus
    , jobPeriod :: A.Value
    , jobAdvice :: Text
    , jobError  :: Maybe Text
    }

type AdviceJobs = TVar (M.Map Text AdviceJob)

adviceSystemPrompt :: Text
adviceSystemPrompt = intercalate "\n"
    [ "あなたはOura Ringの健康データを解析する専門家アシスタントです。"
    , "ユーザーから過去14日間のOura Ringデータ（睡眠、準備度、活動量、ストレス、血中酸素濃度、体温偏差、回復力、VO2 Max、心血管年齢）が提供されます。"
    , "`sleep_periods` は各日の睡眠段階の実時間（秒）です。同じ日の本睡と仮眠を合算しています。"
    , "`bedtime_start`（就床）・`sleep_onset`（入眠）・`bedtime_end`（起床）はその日の本睡の時刻（記録地の時刻、HH:MM）です。`naps` は仮眠の回数、`nap_time_in_bed` はその合計時間（秒）です。"
    , ""
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
    , "### ⚠️ 注目ポイント"
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
            Activity    -> [("active_calories", g "active_calories"), ("steps", g "steps")]
            Stress      -> [("stress_high", g "stress_high"), ("recovery_high", g "recovery_high")]
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

-- | The main period's clock times plus the nap count and their time in bed.
sleepTimes :: [A.Value] -> [(A.Key, A.Value)]
sleepTimes rows =
    [ ("bedtime_start", A.toJSON (clockAt 0 =<< start))
    , ("sleep_onset",   A.toJSON (clockAt latency =<< start))
    , ("bedtime_end",   A.toJSON (clockAt 0 =<< str "bedtime_end"))
    , ("naps",            A.toJSON (length naps))
    , ("nap_time_in_bed", A.toJSON (sum (map (periodSeconds "time_in_bed") naps)))
    ]
  where
    primary = mainSleepPeriod rows
    naps = filter ((/= primary) . Just) rows
    str k = jsonText =<< jsonLookup k =<< primary
    start = str "bedtime_start"
    latency = maybe 0 (periodSeconds "latency") primary

-- | The long sleep if the day has one, otherwise its longest period by time in
-- bed (the first of equals). A late nap is never the night's sleep, so a day
-- holding nothing else has no main period. Mirrors @mainPeriod@ in
-- static/helpers.js.
mainSleepPeriod :: [A.Value] -> Maybe A.Value
mainSleepPeriod rows =
    find ((== Just "long_sleep") . sleepType) candidates
        <|> headMay (sortOn (Down . periodSeconds "time_in_bed") candidates)
  where
    sleepType = jsonText <=< jsonLookup "type"
    candidates = filter ((/= Just "late_nap") . sleepType) rows

-- | "HH:MM" on the wall clock where the period was recorded, @offset@ seconds
-- after the given ISO 8601 timestamp. The timestamp's own UTC offset is kept
-- rather than converting to the server's zone, so a night abroad reads as the
-- local time it was slept.
clockAt :: Int -> Text -> Maybe Text
clockAt offset ts =
    pack . formatTime defaultTimeLocale "%H:%M"
         . addLocalTime (fromIntegral offset) . zonedTimeToLocalTime
        <$> iso8601ParseM (unpack ts)

periodSeconds :: Text -> A.Value -> Int
periodSeconds f r = fromMaybe 0 (jsonInt =<< jsonLookup f r)

-- | Build the 14-day health payload (period + per-metric key fields).
buildHealthPayload :: (MonadIO m) => DayText -> Int -> ReaderT SqlBackend m A.Value
buildHealthPayload today days = do
    let start = addDaysT (negate (fromIntegral days - 1)) today
        range = DateRange start today
    bulk <- getDailyMetricsBulk dashboardMetrics range
    sleepPeriods <- getSleepPeriods range
    let metricsObj = KM.fromList
            [ ( K.fromText (dailyMetricName m)
              , A.toJSON (map (extractKeyFields m) (M.findWithDefault [] m bulk)) )
            | m <- dashboardMetrics ]
        period = A.object ["start" A..= start, "end" A..= today, "days" A..= days]
    return $ A.object
        [ "period"        A..= period
        , "metrics"       A..= A.Object metricsObj
        , "sleep_periods" A..= sleepStageTotals sleepPeriods
        ]

-- | Build the prompt string (system prompt + JSON code block).
buildAdvicePrompt :: A.Value -> Text
buildAdvicePrompt healthData =
    adviceSystemPrompt <> "\n\n```json\n" <> prettyJson <> "\n```"
  where
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }

-- TVar job map -----------------------------------------------------------

newAdviceJobs :: IO AdviceJobs
newAdviceJobs = newTVarIO M.empty

-- | Create a queued job with a fresh UUID and return its id.
createAdviceJob :: AdviceJobs -> A.Value -> IO Text
createAdviceJob jobs period = do
    jid <- UUID.toText <$> UUID.nextRandom
    let job = AdviceJob jid Queued period "" Nothing
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
    let cp = proc "claude"
            [ "-p", unpack prompt, "--max-turns", "1", "--model", "opus"
            , "--append-system-prompt", appendSystemPrompt ]
    result <- try (timeout (120 * 1000000) (readCreateProcessWithExitCode cp ""))
    case result of
        Left (_ :: IOException) ->
            fail' "claude コマンドが見つかりません。Claude Code がインストールされているか確認してください。"
        Right Nothing ->
            fail' "分析がタイムアウトしました。"
        Right (Just (ExitFailure _, out, err)) ->
            fail' (if null err
                       then if null out
                                then "Claude Code の実行に失敗しました。"
                                else "Claude Code の実行に失敗しました: " <> pack out
                       else pack err)
        Right (Just (ExitSuccess, out, _)) -> do
            let adviceOut = pack out
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
