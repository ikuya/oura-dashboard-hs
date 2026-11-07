{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Advice job logic.
--
-- Jobs live in an in-process 'TVar' map and run in a 'forkIO' worker that
-- shells out to the @claude@ CLI. Jobs are non-persistent: they vanish on
-- restart.
module Advice
    ( AdviceJob (..)
    , JobStatus (..)
    , statusText
    , AdviceJobs
    , AdviceError (..)
    , adviceErrorCode
    , adviceErrorDetail
    , adviceErrorMessage
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
import System.Process             (readCreateProcessWithExitCode, proc)
import System.Timeout             (timeout)
import qualified Data.UUID         as UUID
import qualified Data.UUID.V4      as UUID
import Control.Monad              (mfilter)
import Control.Monad.Logger       (LogLevel (..))
import Data.Time.Clock            (diffUTCTime)
import Data.Time.Format.ISO8601   (iso8601ParseM)
import Data.Time.LocalTime        (addLocalTime, zonedTimeToLocalTime,
                                   zonedTimeToUTC)

import DateText                   (DateRange (..), DayText (..), addDaysT)
import Db
import Json                       (jsonDouble, jsonText, jsonLookup)
import Language                   (Language (..))
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
    , jobError      :: Maybe AdviceError
    }

type AdviceJobs = TVar (M.Map Text AdviceJob)

-- | The language-specific parts of the report: the language it is written
-- in, its section headings, and what the "points to watch" section says when
-- there is nothing to point out. The rest of the prompt is the same English
-- instruction for every language.
data AdviceStrings = AdviceStrings
    { languageName   :: Text
    , headingStatus  :: Text
    , headingChanges :: Text
    , headingWatch   :: Text
    , headingAdvice  :: Text
    , nothingNotable :: Text
    }

adviceStrings :: Language -> AdviceStrings
adviceStrings Ja = AdviceStrings
    { languageName   = "Japanese"
    , headingStatus  = "📊 現在の健康状態"
    , headingChanges = "🔁 前回からの変化"
    , headingWatch   = "⚠️ 注目ポイント"
    , headingAdvice  = "💡 アドバイス"
    , nothingNotable = "特になし"
    }
adviceStrings En = AdviceStrings
    { languageName   = "English"
    , headingStatus  = "📊 Current Health"
    , headingChanges = "🔁 Changes Since Last Time"
    , headingWatch   = "⚠️ Points to Watch"
    , headingAdvice  = "💡 Advice"
    , nothingNotable = "Nothing in particular"
    }

-- | The system prompt for a report in the given language. With a previous
-- advice to follow on from, the report gains a section on what changed since
-- then.
adviceSystemPrompt :: Language -> Maybe SavedAdvice -> Text
adviceSystemPrompt lang previous = intercalate "\n" $
    [ "You are an expert assistant who analyses health data from an Oura Ring."
    , "The user provides the last " <> tshow adviceDays <> " days of Oura Ring data (sleep, readiness, activity, stress, blood oxygen, temperature deviation, resilience, VO2 Max and cardiovascular age)."
    , "`sleep_periods` holds each day's actual time in each sleep stage, in seconds, summing that day's main sleep and its naps."
    , "`bedtime_start` (into bed), `sleep_onset` (fell asleep) and `bedtime_end` (woke up) are the clock times of that day's main sleep (local time where it was recorded, HH:MM). `naps` is the number of naps and `nap_time_in_bed` their total time in bed, in seconds."
    , "`average_hrv` (mean overnight HRV, ms), `lowest_heart_rate` (bpm), `average_heart_rate` (bpm) and `average_breath` (breaths per minute) are also from that day's main sleep."
    , "`tags` are tags the user added in the Oura app (`tag` is the type code or a free-text name; e.g. `tag_sleep_alcohol` means alcohol), `workouts` are workouts (`minutes` is the duration, `start` the start time) and `sessions` are sessions such as meditation or rest. A tag or workout on day D can affect that night's sleep (the `sleep_periods` and `sleep` of D+1) and the next morning's readiness (the `readiness` of D+1); where one does, point out the link concretely."
    ]
    ++ whenPrevious
    [ "After the data, `<previous_advice>` holds the previous advice. Focusing on the days after it was saved, assess from the data how the points and suggestions it made have turned out. Do not repeat a suggestion that shows no improvement in the same words; offer a different angle instead. The previous advice may be written in another language; write in " <> language <> " regardless." ]
    ++
    [ ""
    , "## Role"
    , "1. Analyse the data objectively and summarise the current state of health concisely"
    , "2. Identify trends and notable changes"
    , "3. Give practical, specific advice"
    , ""
    , "## Output format"
    , "Structure the report as follows, using these headings exactly:"
    , ""
    , "### " <> headingStatus strings
    , "(Summarise each metric's latest values and trend in 2-3 sentences)"
    , ""
    ]
    ++ whenPrevious
    [ "### " <> headingChanges strings
    , "(In 2-4 bullet points, assess what improved or worsened since the previous advice and whether its suggestions show an effect)"
    , ""
    ]
    ++
    [ "### " <> headingWatch strings
    , "(Bullet the changes of concern and the items that need improving. If all is well, write \"" <> nothingNotable strings <> "\")"
    , ""
    , "### " <> headingAdvice strings
    , "(3-5 bullet points of specific actions based on the data)"
    , ""
    , "---"
    , "- Write the entire report in " <> language
    , "- Score thresholds: 80 and above = good (green), 60-79 = fair (yellow), below 60 = needs attention (red)"
    , "- A temperature deviation within ±0.5°C is in the normal range"
    , "- Do not make medical diagnoses"
    , ""
    ]
  where
    strings = adviceStrings lang
    language = languageName strings
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
        , "tag"     A..= (nonBlank "custom_name" <|> nonBlank "tag_type_code")
        , "time"    A..= (clockAt 0 =<< str "start_time")
        , "comment" A..= nonBlank "comment" ]
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
    -- Oura sends an unset custom name as null and an unset comment as "".
    nonBlank k = mfilter (not . null) (str k)
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
buildAdvicePrompt :: Language -> Maybe SavedAdvice -> A.Value -> Text
buildAdvicePrompt lang previous healthData =
    adviceSystemPrompt lang previous <> "\n\n```json\n" <> prettyJson <> "\n```"
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

-- | Why a report could not be had. The web shows each as a message in the
-- dashboard's language (keyed by 'adviceErrorCode'); logs use the English
-- 'adviceErrorMessage'.
data AdviceError
    = ClaudeNotFound
    -- ^ The @claude@ command is not on the PATH.
    | ClaudeFailed (Maybe Text)
    -- ^ The CLI failed to start or exited non-zero, with what it said.
    | AdviceTimeout
    -- ^ No report within 'generateTimeout'.
    deriving (Eq, Show)

-- | A stable code for the API, which the dashboard translates.
adviceErrorCode :: AdviceError -> Text
adviceErrorCode ClaudeNotFound   = "claude_not_found"
adviceErrorCode (ClaudeFailed _) = "claude_failed"
adviceErrorCode AdviceTimeout    = "timeout"

-- | What the CLI itself said when it failed, for the dashboard to show under
-- its translated message.
adviceErrorDetail :: AdviceError -> Maybe Text
adviceErrorDetail (ClaudeFailed detail) = detail
adviceErrorDetail _                     = Nothing

-- | An English description for logs and API clients without a translation.
adviceErrorMessage :: AdviceError -> Text
adviceErrorMessage ClaudeNotFound =
    "claude command not found; check that Claude Code is installed"
adviceErrorMessage (ClaudeFailed detail) =
    "claude CLI failed" <> foldMap (": " <>) detail
adviceErrorMessage AdviceTimeout = "analysis timed out"

-- | How long the CLI may take, in seconds.
generateTimeout :: Int
generateTimeout = 120

-- | Run the claude CLI on a prompt: the report, or why it could not be had.
-- Shared by the web's advice jobs and the scheduled CLI.
--
-- The report needs no tools, and the prompt carries free text from the Oura
-- app (tag names and comments), so every built-in tool is disabled and no MCP
-- server is loaded: injected instructions have nothing to act through.
generateAdvice :: Text -> IO (Either AdviceError Text)
generateAdvice prompt = do
    let cp = proc "claude"
            [ "-p", unpack prompt, "--max-turns", "1", "--model", "opus"
            , "--tools", "", "--strict-mcp-config"
            , "--append-system-prompt", appendSystemPrompt ]
    result <- try (timeout (generateTimeout * 1000000) (readCreateProcessWithExitCode cp ""))
    return $ case result of
        Left (e :: IOException)
            | isDoesNotExistError e -> Left ClaudeNotFound
            | otherwise             -> Left (ClaudeFailed (Just (tshow e)))
        Right Nothing -> Left AdviceTimeout
        Right (Just (ExitFailure _, out, err)) ->
            Left (ClaudeFailed (mfilter (not . null) (Just (pack err))
                                <|> mfilter (not . null) (Just (pack out))))
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
        Left err -> fail' err
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
    fail' err = do
        setJob jobs jid (\j -> j { jobStatus = Failed, jobError = Just err })
        writeLog appLog LevelError
            ("advice job " <> jid <> " failed: " <> adviceErrorMessage err)

    elapsedSince t0 = do
        now <- getCurrentTime
        return (tshow (diffUTCTime now t0))
    periodBounds v = (,) <$> field "start" <*> field "end"
      where
        field k = DayText <$> (jsonText =<< jsonLookup k v)
