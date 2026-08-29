{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Port of the Python test_app.py API tests (auth, metrics, heartrate, sync).
-- Advice endpoints are covered separately once Phase 5 lands.
module AppSpec (spec) where

import TestImport
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Map.Strict as M
import Database.Persist.Sql (rawExecute, toPersistValue)
import Advice (AdviceJob (..), JobStatus (..))

-- | Log in with the test password (matches config/test-settings.yml hash).
login :: YesodExample App ()
login = do
    request $ do
        setMethod "POST"
        setUrl LoginR
        setRequestBody "{\"password\":\"test-password\"}"
        addRequestHeader ("Content-Type", "application/json")

-- | A stub Oura client returning fixed sleep records; used by the sync test.
syncStubClient :: OuraClient
syncStubClient = OuraClient
    { getDailySleep = \_ -> return
        [ A.object ["day" .= ("2024-01-10" :: Text), "score" .= (80 :: Int)] ]
    , getDailyReadiness = e, getDailyActivity = e, getDailyStress = e
    , getDailySpo2 = e, getDailyResilience = e, getDailyCardiovascularAge = e
    , getVO2Max = e, getHeartrate = e, getSleepPeriods = e }
  where e _ = return []

spec :: Spec
spec = do
    describe "auth" $ withApp $ do
        it "login succeeds with correct password" $ do
            login
            statusIs 200

        it "login fails with wrong password" $ do
            request $ do
                setMethod "POST"
                setUrl LoginR
                setRequestBody "{\"password\":\"wrong\"}"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 401

        -- A body that cannot be parsed is treated as {} (no password), the way
        -- Flask's get_json(silent=True) did, rather than surfacing as a 500.
        it "login with malformed JSON returns 401" $ do
            request $ do
                setMethod "POST"
                setUrl LoginR
                setRequestBody "{not json"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 401

        it "login with no body returns 401" $ do
            request $ setMethod "POST" >> setUrl LoginR
            statusIs 401

        it "login with non-JSON content type returns 401" $ do
            request $ do
                setMethod "POST"
                setUrl LoginR
                setRequestBody "{\"password\":\"test-password\"}"
                addRequestHeader ("Content-Type", "text/plain")
            statusIs 401

        it "logout then protected endpoint returns 401" $ do
            login
            request $ setMethod "POST" >> setUrl LogoutR
            statusIs 200
            get MetricsR
            statusIs 401

        it "protected endpoint requires auth" $ do
            get MetricsR
            statusIs 401

    describe "metrics" $ withApp $ do
        it "empty metrics returns 200 object" $ do
            login
            request $ setMethod "GET" >> setUrl MetricsR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200

        it "metrics with data returns the row" $ do
            login
            insertMetric "sleep" "2024-01-10" (Just 80) "{\"score\":80}"
            request $ setMethod "GET" >> setUrl MetricsR
                >> addGetParam "metric" "sleep"
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "\"score\":80"

        it "ignores unknown metric" $ do
            login
            request $ setMethod "GET" >> setUrl MetricsR
                >> addGetParam "metric" "sleep,unknown_metric"
            statusIs 200
            bodyContains "sleep"
            bodyNotContains "unknown_metric"

        it "single metric valid" $ do
            login
            insertMetric "readiness" "2024-01-05" (Just 75) "{\"score\":75}"
            request $ setMethod "GET" >> setUrl (MetricR "readiness")
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "\"score\":75"

        it "single metric unknown returns 400" $ do
            login
            get (MetricR "unknown")
            statusIs 400

        it "an invalid date query param returns 400" $ do
            login
            request $ setMethod "GET" >> setUrl MetricsR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-02-31"
            statusIs 400

    describe "heartrate" $ withApp $ do
        it "returns heartrate rows" $ do
            login
            insertHr "2024-01-10T12:00:00" 65 "2024-01-10"
            request $ setMethod "GET" >> setUrl HeartrateR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "\"bpm\":65"

    describe "sleep periods" $ withApp $ do
        it "returns periods in the range" $ do
            login
            insertSleepPeriod "a" "2024-01-10" "2024-01-09T23:30:00+09:00" "long_sleep"
            request $ setMethod "GET" >> setUrl SleepPeriodsR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "\"sleep_phase_5_min\":\"4123\""

        it "excludes periods outside the range" $ do
            login
            insertSleepPeriod "a" "2024-02-10" "2024-02-09T23:30:00+09:00" "long_sleep"
            request $ setMethod "GET" >> setUrl SleepPeriodsR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "[]"

        it "excludes rest periods" $ do
            login
            insertSleepPeriod "a" "2024-01-10" "2024-01-10T14:00:00+09:00" "rest"
            request $ setMethod "GET" >> setUrl SleepPeriodsR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "[]"

        it "requires auth" $ do
            get SleepPeriodsR
            statusIs 401

    describe "sync status" $ withApp $ do
        it "reports sleep and heartrate" $ do
            login
            get SyncStatusR
            statusIs 200
            bodyContains "sleep"
            bodyContains "heartrate"

    describe "sync (stub client)" $ withAppClient (Just syncStubClient) $ do
        it "trigger sync returns 202 with synced counts" $ do
            login
            request $ do
                setMethod "POST"
                setUrl SyncR
                setRequestBody "{\"start\":\"2024-01-01\",\"end\":\"2024-01-31\",\"metrics\":[\"sleep\"]}"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 202
            bodyContains "synced"

        it "sync with malformed JSON body uses defaults and returns 202" $ do
            login
            request $ do
                setMethod "POST"
                setUrl SyncR
                setRequestBody "{ not json"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 202
            bodyContains "synced"

        it "sync with no body uses defaults and returns 202" $ do
            login
            request $ setMethod "POST" >> setUrl SyncR
            statusIs 202
            bodyContains "synced"

        -- An impossible "end" used to reach the heartrate window arithmetic,
        -- where parseDay called error and the request died as a 500.
        it "sync with an impossible end date returns 400" $ do
            login
            request $ do
                setMethod "POST"
                setUrl SyncR
                setRequestBody "{\"end\":\"1999-13-45\",\"metrics\":[\"heartrate\"]}"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 400

        it "sync with a malformed start date returns 400" $ do
            login
            request $ do
                setMethod "POST"
                setUrl SyncR
                setRequestBody "{\"start\":\"not-a-date\"}"
                addRequestHeader ("Content-Type", "application/json")
            statusIs 400

    describe "advice" $ withApp $ do
        it "POST /api/advice with no data returns 400" $ do
            login
            request $ setMethod "POST" >> setUrl AdviceR
            statusIs 400

        it "job not found returns 404" $ do
            login
            get (AdviceJobR "unknown-job")
            statusIs 404

        it "completed job returns 200 with advice" $ do
            login
            insertJob "job-done" Completed "健康状態は良好です。" Nothing
            get (AdviceJobR "job-done")
            statusIs 200
            bodyContains "健康状態は良好です。"

        it "failed job returns 502" $ do
            login
            insertJob "job-failed" Failed "" (Just "分析がタイムアウトしました。")
            get (AdviceJobR "job-failed")
            statusIs 502

        it "history list returns saved advice" $ do
            login
            insertAdvice "2024-01-14T10:00:00+00:00" "2024-01-01" "2024-01-14" "some advice"
            get (AdviceJobR "history")
            statusIs 200
            bodyContains "2024-01-14"

        it "history entry valid returns advice" $ do
            login
            insertAdvice "2024-01-14T10:00:00+00:00" "2024-01-01" "2024-01-14" "テストアドバイス"
            get (AdviceEntryR "2024-01-14")
            statusIs 200
            bodyContains "テストアドバイス"

        it "history entry invalid date returns 400" $ do
            login
            get (AdviceEntryR "not-a-date")
            statusIs 400

        it "history entry not found returns 404" $ do
            login
            get (AdviceEntryR "2024-01-01")
            statusIs 404

-- helpers ----------------------------------------------------------------

-- | Insert a job directly into the foundation's TVar (mirrors the Python tests
-- setting _advice_jobs directly).
insertJob :: Text -> JobStatus -> Text -> Maybe Text -> YesodExample App ()
insertJob jid st advice merr = do
    app <- getTestYesod
    let period = A.object ["start" .= ("2024-01-01" :: Text), "end" .= ("2024-01-14" :: Text), "days" .= (14 :: Int)]
        job = AdviceJob jid st period advice merr
    liftIO $ atomically $ modifyTVar' (appAdviceJobs app) (M.insert jid job)

insertAdvice :: Text -> Text -> Text -> Text -> YesodExample App ()
insertAdvice savedAt ps pe content = runDB $ rawExecute
    "INSERT INTO advice_history (saved_at, period_start, period_end, content) VALUES (?, ?, ?, ?)"
    [toPersistValue savedAt, toPersistValue ps, toPersistValue pe, toPersistValue content]

insertMetric :: Text -> Text -> Maybe Double -> Text -> YesodExample App ()
insertMetric metric day score dataJson = runDB $ rawExecute
    "INSERT OR REPLACE INTO daily_metrics (metric, day, score, data_json, synced_at) VALUES (?, ?, ?, ?, ?)"
    [ toPersistValue metric, toPersistValue day, toPersistValue score
    , toPersistValue dataJson, toPersistValue ("2024-01-10T00:00:00+00:00" :: Text) ]

-- | Insert a sleep period whose data_json carries the fields the API projects.
insertSleepPeriod :: Text -> Text -> Text -> Text -> YesodExample App ()
insertSleepPeriod ouraId day bedtimeStart sleepType = runDB $ rawExecute
    "INSERT OR REPLACE INTO sleep_periods (id, day, bedtime_start, bedtime_end, type, data_json, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
    [ toPersistValue ouraId, toPersistValue day
    , toPersistValue bedtimeStart, toPersistValue bedtimeStart
    , toPersistValue sleepType
    , toPersistValue (decodeUtf8 (toStrict (A.encode (A.object
        [ "id" .= ouraId, "day" .= day, "type" .= sleepType
        , "bedtime_start" .= bedtimeStart, "bedtime_end" .= bedtimeStart
        , "sleep_phase_5_min" .= ("4123" :: Text)
        , "sleep_phase_30_sec" .= ("44444444" :: Text)
        ]))))
    , toPersistValue ("2024-01-10T00:00:00+00:00" :: Text) ]

insertHr :: Text -> Int -> Text -> YesodExample App ()
insertHr ts bpm day = runDB $ rawExecute
    "INSERT INTO heartrate (timestamp, bpm, day) VALUES (?, ?, ?)"
    [toPersistValue ts, toPersistValue bpm, toPersistValue day]
