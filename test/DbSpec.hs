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
                upsertDailyMetric "sleep" "2024-01-01" (Just 85)
                    (A.object ["score" .= (85 :: Int), "day" .= ("2024-01-01" :: Text)])
                getDailyMetrics "sleep" "2024-01-01" "2024-01-01"
            length rows `shouldBe` 1
            field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-01")
            field "score" (headEx rows) `shouldBe` Just (A.Number 85)

        it "replaces an existing record" $ do
            rows <- runMem $ do
                upsertDailyMetric "sleep" "2024-01-01" (Just 70) (A.object ["score" .= (70 :: Int)])
                upsertDailyMetric "sleep" "2024-01-01" (Just 90) (A.object ["score" .= (90 :: Int)])
                getDailyMetrics "sleep" "2024-01-01" "2024-01-01"
            length rows `shouldBe` 1
            field "score" (headEx rows) `shouldBe` Just (A.Number 90)

        it "respects the date range" $ do
            rows <- runMem $ do
                forM_ [("2024-01-01", 70), ("2024-01-05", 80), ("2024-01-10", 90)] $ \(d, s) ->
                    upsertDailyMetric "sleep" d (Just s) (A.object ["score" .= s])
                getDailyMetrics "sleep" "2024-01-03" "2024-01-07"
            length rows `shouldBe` 1
            field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-05")

        it "returns rows sorted by day" $ do
            rows <- runMem $ do
                forM_ ["2024-01-03", "2024-01-01", "2024-01-02"] $ \d ->
                    upsertDailyMetric "readiness" d (Just 75) (A.object ["score" .= (75 :: Int)])
                getDailyMetrics "readiness" "2024-01-01" "2024-01-03"
            let days = mapMaybe (field "day") rows
            days `shouldBe` [A.String "2024-01-01", A.String "2024-01-02", A.String "2024-01-03"]

        it "merges json fields" $ do
            rows <- runMem $ do
                upsertDailyMetric "sleep" "2024-01-01" (Just 80)
                    (A.object ["score" .= (80 :: Int), "contributors" .= A.object ["deep_sleep" .= (90 :: Int)]])
                getDailyMetrics "sleep" "2024-01-01" "2024-01-01"
            field "contributors" (headEx rows)
                `shouldBe` Just (A.object ["deep_sleep" .= (90 :: Int)])

    describe "get_daily_metrics_bulk" $ do
        it "returns rows keyed by metric" $ do
            result <- runMem $ do
                upsertDailyMetric "sleep" "2024-01-01" (Just 80) (A.object ["score" .= (80 :: Int)])
                upsertDailyMetric "readiness" "2024-01-01" (Just 70) (A.object ["score" .= (70 :: Int)])
                getDailyMetricsBulk ["sleep", "readiness", "activity"] "2024-01-01" "2024-01-01"
            (field "score" =<< headMay (M.findWithDefault [] "sleep" result))
                `shouldBe` Just (A.Number 80)
            (field "score" =<< headMay (M.findWithDefault [] "readiness" result))
                `shouldBe` Just (A.Number 70)
            M.lookup "activity" result `shouldBe` Just []

        it "returns empty map for empty metrics" $ do
            result <- runMem $ getDailyMetricsBulk [] "2024-01-01" "2024-01-31"
            result `shouldBe` M.empty

    describe "upsert_heartrate_batch / get_heartrate" $ do
        it "inserts records" $ do
            (count, rows) <- runMem $ do
                c <- upsertHeartrateBatch
                    [("2024-01-01T00:00:00", Just 60), ("2024-01-01T00:01:00", Just 62)]
                rs <- getHeartrate "2024-01-01" "2024-01-01"
                return (c, rs)
            count `shouldBe` 2
            length rows `shouldBe` 2

        it "ignores duplicate timestamps" $ do
            rows <- runMem $ do
                _ <- upsertHeartrateBatch [("2024-01-01T00:00:00", Just 60)]
                _ <- upsertHeartrateBatch [("2024-01-01T00:00:00", Just 60)]
                getHeartrate "2024-01-01" "2024-01-01"
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
                getHeartrate "2024-01-03" "2024-01-07"
            length rows `shouldBe` 1
            field "bpm" (headEx rows) `shouldBe` Just (A.Number 65)

    describe "sync_log" $ do
        it "updates and gets last synced day" $ do
            d <- runMem $ do
                updateSyncLog "sleep" "2024-01-15"
                getLastSyncedDay "sleep"
            d `shouldBe` Just "2024-01-15"

        it "returns Nothing when not synced" $ do
            d <- runMem $ getLastSyncedDay "sleep"
            d `shouldBe` Nothing

        it "replaces old value" $ do
            d <- runMem $ do
                updateSyncLog "sleep" "2024-01-10"
                updateSyncLog "sleep" "2024-01-20"
                getLastSyncedDay "sleep"
            d `shouldBe` Just "2024-01-20"

    describe "advice_history" $ do
        it "saves and gets advice by saved_at date" $ do
            entry <- runMem $ do
                saveAdvice "2024-01-01" "2024-01-14" "健康状態は良好です。"
                -- saved_at uses today's date; fetch dates then look up.
                dates <- getAdviceDates
                case dates of
                    (d : _) -> case field "day" d of
                        Just (A.String day) -> getAdviceForDate day
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

    describe "get_sync_status" $ do
        it "reports all metrics" $ do
            status <- runMem getSyncStatus
            case status of
                A.Object o ->
                    sort (KM.keys o) `shouldBe` sort
                        [ "sleep", "readiness", "activity", "stress", "spo2"
                        , "resilience", "cardiovascular_age", "vo2_max"
                        , "temperature", "heartrate" ]
                _ -> expectationFailure "status is not an object"

        it "counts rows" $ do
            status <- runMem $ do
                upsertDailyMetric "sleep" "2024-01-01" (Just 80) (A.object ["score" .= (80 :: Int)])
                upsertDailyMetric "sleep" "2024-01-02" (Just 85) (A.object ["score" .= (85 :: Int)])
                updateSyncLog "sleep" "2024-01-02"
                getSyncStatus
            let sleepRows = field "sleep" status >>= field "rows"
                sleepLast = field "sleep" status >>= field "last_day"
            sleepRows `shouldBe` Just (A.Number 2)
            sleepLast `shouldBe` Just (A.String "2024-01-02")

-- | Insert an advice_history row with an explicit saved_at (for grouping tests).
insertAdviceRaw
    :: (MonadIO m)
    => Text -> Text -> Text -> Text -> SqlPersistT m ()
insertAdviceRaw savedAt ps pe content =
    rawExecute
        "INSERT INTO advice_history (saved_at, period_start, period_end, content) VALUES (?, ?, ?, ?)"
        [ toPersistValue savedAt, toPersistValue ps
        , toPersistValue pe, toPersistValue content ]
