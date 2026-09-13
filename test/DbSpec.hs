{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

-- | Port of the Python test_db.py suite, run against an in-memory SQLite
-- database with the Persistent schema applied.
module DbSpec (spec) where

import ClassyPrelude
import Test.Hspec
import Database.Persist.Sqlite (runSqlite, runMigrationSilent)
import Database.Persist.Sql    (SqlPersistT, rawExecute, toPersistValue)
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as M

import DateText
import Metric
import Model (migrateAll)
import Db

-- | Run a DB action against a fresh in-memory database with the schema
-- migrated. Each call gets an isolated database (like the mem_conn fixture).
-- Signature left to inference to avoid importing the ResourceT/NoLoggingT
-- stack that runSqlite fixes internally.
runMem action = runSqlite ":memory:" $ do
    _ <- runMigrationSilent migrateAll
    action

-- | Extract a field from an aeson Value (Object) for assertions.
field :: Text -> A.Value -> Maybe A.Value
field k (A.Object o) = KM.lookup (K.fromText k) o
field _ _            = Nothing

spec :: Spec
spec = do
    describe "upsert_daily_metric / get_daily_metrics" $ do
        it "upserts and gets a daily metric" $ do
            rows <- runMem $ do
                upsertDailyMetric Sleep "2024-01-01" (Just 85)
                    (A.object ["score" .= (85 :: Int), "day" .= ("2024-01-01" :: Text)])
                getDailyMetrics Sleep (DateRange "2024-01-01" "2024-01-01")
            length rows `shouldBe` 1
            field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-01")
            field "score" (headEx rows) `shouldBe` Just (A.Number 85)

        it "replaces an existing record" $ do
            rows <- runMem $ do
                upsertDailyMetric Sleep "2024-01-01" (Just 70) (A.object ["score" .= (70 :: Int)])
                upsertDailyMetric Sleep "2024-01-01" (Just 90) (A.object ["score" .= (90 :: Int)])
                getDailyMetrics Sleep (DateRange "2024-01-01" "2024-01-01")
            length rows `shouldBe` 1
            field "score" (headEx rows) `shouldBe` Just (A.Number 90)

        it "respects the date range" $ do
            rows <- runMem $ do
                forM_ [("2024-01-01", 70), ("2024-01-05", 80), ("2024-01-10", 90)] $ \(d, s) ->
                    upsertDailyMetric Sleep d (Just s) (A.object ["score" .= s])
                getDailyMetrics Sleep (DateRange "2024-01-03" "2024-01-07")
            length rows `shouldBe` 1
            field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-05")

        it "returns rows sorted by day" $ do
            rows <- runMem $ do
                forM_ ["2024-01-03", "2024-01-01", "2024-01-02"] $ \d ->
                    upsertDailyMetric Readiness d (Just 75) (A.object ["score" .= (75 :: Int)])
                getDailyMetrics Readiness (DateRange "2024-01-01" "2024-01-03")
            let days = mapMaybe (field "day") rows
            days `shouldBe` [A.String "2024-01-01", A.String "2024-01-02", A.String "2024-01-03"]

        it "merges json fields" $ do
            rows <- runMem $ do
                upsertDailyMetric Sleep "2024-01-01" (Just 80)
                    (A.object ["score" .= (80 :: Int), "contributors" .= A.object ["deep_sleep" .= (90 :: Int)]])
                getDailyMetrics Sleep (DateRange "2024-01-01" "2024-01-01")
            field "contributors" (headEx rows)
                `shouldBe` Just (A.object ["deep_sleep" .= (90 :: Int)])

    describe "get_daily_metrics_bulk" $ do
        it "returns rows keyed by metric" $ do
            result <- runMem $ do
                upsertDailyMetric Sleep "2024-01-01" (Just 80) (A.object ["score" .= (80 :: Int)])
                upsertDailyMetric Readiness "2024-01-01" (Just 70) (A.object ["score" .= (70 :: Int)])
                getDailyMetricsBulk [Sleep, Readiness, Activity] (DateRange "2024-01-01" "2024-01-01")
            (field "score" =<< headMay (M.findWithDefault [] Sleep result))
                `shouldBe` Just (A.Number 80)
            (field "score" =<< headMay (M.findWithDefault [] Readiness result))
                `shouldBe` Just (A.Number 70)
            M.lookup Activity result `shouldBe` Just []

        it "returns empty map for empty metrics" $ do
            result <- runMem $ getDailyMetricsBulk [] (DateRange "2024-01-01" "2024-01-31")
            result `shouldBe` M.empty

    describe "upsert_heartrate_batch / get_heartrate" $ do
        it "inserts records" $ do
            (count, rows) <- runMem $ do
                c <- upsertHeartrateBatch
                    [("2024-01-01T00:00:00", Just 60), ("2024-01-01T00:01:00", Just 62)]
                rs <- getHeartrate (DateRange "2024-01-01" "2024-01-01")
                return (c, rs)
            count `shouldBe` 2
            length rows `shouldBe` 2

        it "ignores duplicate timestamps" $ do
            rows <- runMem $ do
                _ <- upsertHeartrateBatch [("2024-01-01T00:00:00", Just 60)]
                _ <- upsertHeartrateBatch [("2024-01-01T00:00:00", Just 60)]
                getHeartrate (DateRange "2024-01-01" "2024-01-01")
            length rows `shouldBe` 1

        it "skips invalid records" $ do
            count <- runMem $ upsertHeartrateBatch
                [("", Just 60), ("2024-01-01T01:00:00", Nothing), ("2024-01-01T02:00:00", Just 65)]
            count `shouldBe` 1

        it "respects the date range" $ do
            rows <- runMem $ do
                _ <- upsertHeartrateBatch
                    [ ("2024-01-01T12:00:00", Just 60)
                    , ("2024-01-05T12:00:00", Just 65)
                    , ("2024-01-10T12:00:00", Just 70) ]
                getHeartrate (DateRange "2024-01-03" "2024-01-07")
            length rows `shouldBe` 1
            field "bpm" (headEx rows) `shouldBe` Just (A.Number 65)

    describe "sync_log" $ do
        it "updates and gets last synced day" $ do
            d <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-15"
                getLastSyncedDay (Daily Sleep)
            d `shouldBe` Just "2024-01-15"

        it "returns Nothing when not synced" $ do
            d <- runMem $ getLastSyncedDay (Daily Sleep)
            d `shouldBe` Nothing

        it "replaces old value" $ do
            d <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-10"
                updateSyncLog (Daily Sleep) "2024-01-20"
                getLastSyncedDay (Daily Sleep)
            d `shouldBe` Just "2024-01-20"

    describe "advice_history" $ do
        it "saves and gets advice by saved_at date" $ do
            entry <- runMem $ do
                saveAdvice "2024-01-01" "2024-01-14" "健康状態は良好です。"
                -- saved_at uses today's date; fetch dates then look up.
                dates <- getAdviceDates
                case dates of
                    (d : _) -> case field "day" d of
                        Just (A.String day) -> getAdviceForDate (DayText day)
                        _ -> return Nothing
                    _ -> return Nothing
            (field "content" =<< entry) `shouldBe` Just (A.String "健康状態は良好です。")
            (field "period_start" =<< entry) `shouldBe` Just (A.String "2024-01-01")
            (field "period_end" =<< entry) `shouldBe` Just (A.String "2024-01-14")

        it "returns Nothing when missing" $ do
            entry <- runMem $ getAdviceForDate "2024-01-01"
            entry `shouldBe` Nothing

        it "groups dates by day" $ do
            dates <- runMem $ do
                insertAdviceRaw "2024-01-14T10:00:00+00:00" "2024-01-01" "2024-01-14" "advice A"
                insertAdviceRaw "2024-01-14T12:00:00+00:00" "2024-01-01" "2024-01-14" "advice B"
                insertAdviceRaw "2024-01-20T10:00:00+00:00" "2024-01-07" "2024-01-20" "advice C"
                getAdviceDates
            length dates `shouldBe` 2
            (field "day" =<< headMay dates) `shouldBe` Just (A.String "2024-01-14")
            (field "day" =<< headMay (drop 1 dates)) `shouldBe` Just (A.String "2024-01-20")

    describe "upsert_sleep_periods / get_sleep_periods" $ do
        it "inserts records" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ sleepPeriod "a" "2024-01-01" "2023-12-31T23:30:00+09:00" "long_sleep"
                    , sleepPeriod "b" "2024-01-01" "2024-01-01T14:00:00+09:00" "sleep" ]
                getSleepPeriods (DateRange "2024-01-01" "2024-01-01")
            map (field "id") rows `shouldBe` [Just (A.String "a"), Just (A.String "b")]

        it "replaces a record with the same id" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ sleepPeriod "a" "2024-01-01" "2023-12-31T23:30:00+09:00" "long_sleep" ]
                _ <- upsertSleepPeriods
                    [ (sleepPeriod "a" "2024-01-01" "2023-12-31T23:30:00+09:00" "long_sleep")
                        `withField` ("time_in_bed", A.Number 999) ]
                getSleepPeriods (DateRange "2024-01-01" "2024-01-01")
            length rows `shouldBe` 1
            field "time_in_bed" (headEx rows) `shouldBe` Just (A.Number 999)

        it "skips records without an id or day" $ do
            n <- runMem $ upsertSleepPeriods
                [ sleepPeriod "a" "2024-01-01" "2023-12-31T23:30:00+09:00" "long_sleep"
                , A.object ["day" .= ("2024-01-01" :: Text)]      -- no id
                , A.object ["id" .= ("c" :: Text)]                -- no day
                ]
            n `shouldBe` 1

        it "hides deleted and rest periods" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ sleepPeriod "a" "2024-01-01" "2024-01-01T01:00:00+09:00" "long_sleep"
                    , sleepPeriod "b" "2024-01-01" "2024-01-01T02:00:00+09:00" "rest"
                    , sleepPeriod "c" "2024-01-01" "2024-01-01T03:00:00+09:00" "deleted"
                    , sleepPeriod "d" "2024-01-01" "2024-01-01T04:00:00+09:00" "late_nap" ]
                getSleepPeriods (DateRange "2024-01-01" "2024-01-01")
            map (field "id") rows `shouldBe` [Just (A.String "a"), Just (A.String "d")]

        it "orders by bedtime_start, not by insertion" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ sleepPeriod "late" "2024-01-01" "2024-01-01T14:00:00+09:00" "sleep"
                    , sleepPeriod "early" "2024-01-01" "2023-12-31T23:30:00+09:00" "long_sleep" ]
                getSleepPeriods (DateRange "2024-01-01" "2024-01-01")
            map (field "id") rows
                `shouldBe` [Just (A.String "early"), Just (A.String "late")]

        it "respects the date range" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ sleepPeriod "a" "2024-01-01" "2024-01-01T01:00:00+09:00" "long_sleep"
                    , sleepPeriod "b" "2024-01-05" "2024-01-05T01:00:00+09:00" "long_sleep"
                    , sleepPeriod "c" "2024-01-10" "2024-01-10T01:00:00+09:00" "long_sleep" ]
                getSleepPeriods (DateRange "2024-01-02" "2024-01-09")
            map (field "id") rows `shouldBe` [Just (A.String "b")]

        it "drops the fields the charts never read" $ do
            rows <- runMem $ do
                _ <- upsertSleepPeriods
                    [ (sleepPeriod "a" "2024-01-01" "2024-01-01T01:00:00+09:00" "long_sleep")
                        `withField` ("sleep_phase_30_sec", A.String "4444")
                        `withField` ("movement_30_sec", A.String "1111") ]
                getSleepPeriods (DateRange "2024-01-01" "2024-01-01")
            field "sleep_phase_5_min" (headEx rows) `shouldBe` Just (A.String "4123")
            field "sleep_phase_30_sec" (headEx rows) `shouldBe` Nothing
            field "movement_30_sec" (headEx rows) `shouldBe` Nothing

    describe "get_sync_status" $ do
        it "reports all metrics" $ do
            status <- runMem getSyncStatus
            case status of
                A.Object o ->
                    sort (KM.keys o) `shouldBe` sort
                        [ "sleep", "readiness", "activity", "stress", "spo2"
                        , "resilience", "cardiovascular_age", "vo2_max"
                        , "temperature", "heartrate", "sleep_periods" ]
                _ -> expectationFailure "status is not an object"

        it "counts rows" $ do
            status <- runMem $ do
                upsertDailyMetric Sleep "2024-01-01" (Just 80) (A.object ["score" .= (80 :: Int)])
                upsertDailyMetric Sleep "2024-01-02" (Just 85) (A.object ["score" .= (85 :: Int)])
                updateSyncLog (Daily Sleep) "2024-01-02"
                getSyncStatus
            let sleepRows = field "sleep" status >>= field "rows"
                sleepLast = field "sleep" status >>= field "last_day"
            sleepRows `shouldBe` Just (A.Number 2)
            sleepLast `shouldBe` Just (A.String "2024-01-02")

-- | A sleep period record shaped like the Oura response, with the fields the
-- API projects populated.
sleepPeriod :: Text -> Text -> Text -> Text -> A.Value
sleepPeriod ouraId day bedtimeStart sleepType = A.object
    [ "id" .= ouraId
    , "day" .= day
    , "type" .= sleepType
    , "period" .= (1 :: Int)
    , "bedtime_start" .= bedtimeStart
    , "bedtime_end" .= bedtimeStart
    , "sleep_phase_5_min" .= ("4123" :: Text)
    , "deep_sleep_duration" .= (300 :: Int)
    , "light_sleep_duration" .= (300 :: Int)
    , "rem_sleep_duration" .= (300 :: Int)
    , "awake_time" .= (300 :: Int)
    , "total_sleep_duration" .= (900 :: Int)
    , "time_in_bed" .= (1200 :: Int)
    ]

-- | Add or override one field of a record.
withField :: A.Value -> (Text, A.Value) -> A.Value
withField (A.Object o) (k, v) = A.Object (KM.insert (K.fromText k) v o)
withField other _             = other

-- | Insert an advice_history row with an explicit saved_at (for grouping tests).
insertAdviceRaw
    :: (MonadIO m)
    => Text -> Text -> Text -> Text -> SqlPersistT m ()
insertAdviceRaw savedAt ps pe content =
    rawExecute
        "INSERT INTO advice_history (saved_at, period_start, period_end, content) VALUES (?, ?, ?, ?)"
        [ toPersistValue savedAt, toPersistValue ps
        , toPersistValue pe, toPersistValue content ]
