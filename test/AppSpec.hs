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
    { getDailySleep = \_ _ -> return
        [ A.object ["day" .= ("2024-01-10" :: Text), "score" .= (80 :: Int)] ]
    , getDailyReadiness = e, getDailyActivity = e, getDailyStress = e
    , getDailySpo2 = e, getDailyResilience = e, getDailyCardiovascularAge = e
    , getVO2Max = e, getHeartrate = e }
  where e _ _ = return []

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

    describe "heartrate" $ withApp $ do
        it "returns heartrate rows" $ do
            login
            insertHr "2024-01-10T12:00:00" 65 "2024-01-10"
            request $ setMethod "GET" >> setUrl HeartrateR
                >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
            statusIs 200
            bodyContains "\"bpm\":65"

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

insertHr :: Text -> Int -> Text -> YesodExample App ()
insertHr ts bpm day = runDB $ rawExecute
    "INSERT INTO heartrate (timestamp, bpm, day) VALUES (?, ?, ?)"
    [toPersistValue ts, toPersistValue bpm, toPersistValue day]
