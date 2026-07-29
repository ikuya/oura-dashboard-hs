{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

-- | Port of the Python test_sync.py suite. The OuraClient is a recording stub
-- (mirroring MagicMock): it returns configured records and captures the
-- (metric, start, end) of every call so tests can assert on fetched ranges.
module SyncSpec (spec) where

import ClassyPrelude
import Test.Hspec
import Database.Persist.Sqlite (runSqlite, runMigrationSilent)
import Database.Persist.Sql    (SqlPersistT, rawExecute, toPersistValue)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.Types as AT
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson ((.=))
import qualified Data.Map.Strict as M
import Data.Time.Calendar (diffDays)

import DateText
import Metric
import Model (migrateAll)
import Db hiding (getHeartrate)
import Oura
import Sync

runMem action = runSqlite ":memory:" $ do
    _ <- runMigrationSilent migrateAll
    action

-- | A stub client that returns fixed daily/heartrate records and records the
-- (metric, range) of each call into the given IORef.
stubClient :: IORef [(Text, DateRange)] -> [A.Value] -> [A.Value] -> OuraClient
stubClient ref daily heartrate = OuraClient
    { getDailySleep             = rec "sleep" daily
    , getDailyReadiness         = rec "readiness" daily
    , getDailyActivity          = rec "activity" daily
    , getDailyStress            = rec "stress" daily
    , getDailySpo2              = rec "spo2" daily
    , getDailyResilience        = rec "resilience" daily
    , getDailyCardiovascularAge = rec "cardiovascular_age" daily
    , getVO2Max                 = rec "vo2_max" daily
    , getHeartrate              = rec "heartrate" heartrate
    }
  where
    rec metric records range = do
        modifyIORef' ref (++ [(metric, range)])
        return records

-- | A client whose sleep fetch raises an OuraError.
erroringSleepClient :: OuraClient
erroringSleepClient =
    let base = stubClientPure
    in base { getDailySleep = \_ -> throwIO (OuraError (Just 401) "Unauthorized") }

stubClientPure :: OuraClient
stubClientPure = OuraClient
    { getDailySleep = c, getDailyReadiness = c, getDailyActivity = c
    , getDailyStress = c, getDailySpo2 = c, getDailyResilience = c
    , getDailyCardiovascularAge = c, getVO2Max = c, getHeartrate = c }
  where c _ = return []

callsFor :: Text -> [(Text, DateRange)] -> [DateRange]
callsFor metric calls = [ range | (m, range) <- calls, m == metric ]

obj :: [AT.Pair] -> A.Value
obj = A.object

spec :: Spec
spec = do
    describe "find_missing_range" $ do
        it "no history returns default start" $ do
            r <- runMem $ findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
            r `shouldBe` Just (DateRange defaultStart "2024-01-31")

        it "incremental returns day after last synced" $ do
            r <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-10"
                findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
            r `shouldBe` Just (DateRange "2024-01-11" "2024-01-31")

        -- NOTE: The Python test_sync assertions for the following cases never
        -- actually ran: the conftest mem_conn fixture builds sync_log without
        -- last_synced_at, so update_sync_log raises before the assertion. These
        -- expectations follow the real sync.py logic: fetch_start =
        -- min(refetch_start, next_day), where refetch_start = today - 6.
        it "returns Nothing when refetch window is past the capped end" $ do
            -- requested_end far in the past → refetch_start (today-6) > end.
            r <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-31"
                findMissingRange "2024-01-31" (Daily Sleep) "2024-01-10"
            r `shouldBe` Nothing

        it "up-to-date today still refetches the 7-day window" $ do
            r <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-31"
                findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
            r `shouldBe` Just (DateRange "2024-01-25" "2024-01-31")

        it "caps end at today" $ do
            r <- runMem $ findMissingRange "2024-01-15" (Daily Sleep) "2024-01-31"
            (rangeEnd <$> r) `shouldBe` Just "2024-01-15"

    describe "extract_score" $ do
        let n x = Just (A.Number x)
        it "sleep score" $ extractScore Sleep (obj ["score" .= (85 :: Int)]) `shouldBe` n 85
        it "readiness score" $ extractScore Readiness (obj ["score" .= (72 :: Int)]) `shouldBe` n 72
        it "activity score" $ extractScore Activity (obj ["score" .= (60 :: Int)]) `shouldBe` n 60
        it "stress high" $ extractScore Stress (obj ["stress_high" .= (5000 :: Int)]) `shouldBe` n 5000
        it "spo2 nested average" $
            extractScore Spo2 (obj ["spo2_percentage" .= obj ["average" .= (98.5 :: Double)]]) `shouldBe` n 98.5
        it "spo2 scalar" $
            extractScore Spo2 (obj ["spo2_percentage" .= (97.0 :: Double)]) `shouldBe` n 97.0
        it "resilience solid" $ extractScore Resilience (obj ["level" .= ("solid" :: Text)]) `shouldBe` n 3
        it "resilience exceptional" $ extractScore Resilience (obj ["level" .= ("exceptional" :: Text)]) `shouldBe` n 5
        it "resilience unknown" $ extractScore Resilience (obj ["level" .= ("unknown" :: Text)]) `shouldBe` Nothing
        it "cardiovascular_age" $ extractScore CardiovascularAge (obj ["vascular_age" .= (35 :: Int)]) `shouldBe` n 35
        it "temperature deviation" $ extractScore Temperature (obj ["temperature_deviation" .= (0.2 :: Double)]) `shouldBe` n 0.2
        it "vo2_max has no score" $ extractScore VO2Max (obj ["vo2_max" .= (45 :: Int)]) `shouldBe` Nothing

    describe "sync_daily_metric" $ do
        it "writes records" $ do
            (count, rows) <- runMem $ do
                ref <- newIORef []
                let client = stubClient ref
                        [obj ["day" .= ("2024-01-01" :: Text), "score" .= (80 :: Int)]
                        , obj ["day" .= ("2024-01-02" :: Text), "score" .= (85 :: Int)]] []
                c <- syncDailyMetric client Sleep (DateRange "2024-01-01" "2024-01-02")
                rs <- getDailyMetrics Sleep (DateRange "2024-01-01" "2024-01-02")
                return (c, rs)
            count `shouldBe` 2
            length rows `shouldBe` 2

        it "skips records without day" $ do
            count <- runMem $ do
                ref <- newIORef []
                let client = stubClient ref
                        [obj ["score" .= (80 :: Int)]
                        , obj ["day" .= ("2024-01-02" :: Text), "score" .= (85 :: Int)]] []
                syncDailyMetric client Sleep (DateRange "2024-01-01" "2024-01-02")
            count `shouldBe` 1

        it "extracts temperature from readiness" $ do
            rows <- runMem $ do
                ref <- newIORef []
                let client = stubClient ref
                        [obj [ "day" .= ("2024-01-01" :: Text), "score" .= (75 :: Int)
                             , "temperature_deviation" .= (0.3 :: Double)
                             , "temperature_trend_deviation" .= (0.1 :: Double)
                             , "contributors" .= obj ["body_temperature" .= (80 :: Int)] ]] []
                _ <- syncDailyMetric client Readiness (DateRange "2024-01-01" "2024-01-01")
                getDailyMetrics Temperature (DateRange "2024-01-01" "2024-01-01")
            length rows `shouldBe` 1
            (fieldOf "temperature_deviation" =<< headMay rows) `shouldBe` Just (A.Number 0.3)

    describe "run_sync" $ do
        it "returns a summary" $ do
            result <- runMem $ do
                ref <- newIORef []
                runSync "2024-01-31" (stubClient ref [] []) Nothing Nothing Nothing 0
            -- Both maps present (SyncResult has synced + errors)
            M.null (syncErrors result) `shouldBe` True

        it "skips the temperature metric" $ do
            result <- runMem $ do
                ref <- newIORef []
                runSync "2024-01-31" (stubClient ref [] []) Nothing Nothing (Just [Daily Temperature, Daily Sleep]) 0
            M.member (Daily Temperature) (syncedCounts result) `shouldBe` False
            M.member (Daily Sleep) (syncedCounts result) `shouldBe` True

        it "requested_start overrides incremental" $ do
            calls <- runMem $ do
                updateSyncLog (Daily Sleep) "2024-01-20"
                ref <- newIORef []
                _ <- runSync "2024-01-31" (stubClient ref
                        [obj ["day" .= ("2024-01-10" :: Text), "score" .= (80 :: Int)]] [])
                        (Just "2024-01-10") Nothing (Just [Daily Sleep]) 0
                readIORef ref
            callsFor "sleep" calls `shouldBe` [DateRange "2024-01-10" "2024-01-31"]

        it "captures API errors" $ do
            result <- runMem $
                runSync "2024-01-31" erroringSleepClient Nothing Nothing (Just [Daily Sleep]) 0
            M.member (Daily Sleep) (syncErrors result) `shouldBe` True
            M.findWithDefault 0 (Daily Sleep) (syncedCounts result) `shouldBe` 0

        it "heartrate window capped at 30 days" $ do
            calls <- runMem $ do
                ref <- newIORef []
                _ <- runSync "2024-01-31" (stubClient ref [] []) Nothing Nothing (Just [HeartrateSeries]) 0
                readIORef ref
            forM_ (callsFor "heartrate" calls) $ \(DateRange s e) ->
                diffDaysT e s `shouldSatisfy` (<= 29)

        it "heartrate loops to cover full range" $ do
            calls <- runMem $ do
                ref <- newIORef []
                _ <- runSync "2024-03-31" (stubClient ref [] []) Nothing Nothing (Just [HeartrateSeries]) 0
                readIORef ref
            let hr = callsFor "heartrate" calls
            length hr `shouldSatisfy` (> 1)
            (rangeEnd <$> headMay hr) `shouldBe` Just "2024-03-31"

    describe "backfill_ranges" $ do
        it "all missing is one gap" $ do
            ranges <- runMem $ backfillRanges (Daily Sleep) 7 "2024-01-10"
            ranges `shouldBe` [DateRange "2024-01-04" "2024-01-10"]

        it "no gaps returns only today" $ do
            ranges <- runMem $ do
                forM_ [0..6] $ \i -> do
                    let day = addDaysT' (i - 6) "2024-01-10"
                    upsertDailyMetric Sleep day (Just 80) (obj ["day" .= day])
                backfillRanges (Daily Sleep) 7 "2024-01-10"
            ranges `shouldBe` [DateRange "2024-01-10" "2024-01-10"]

        it "single gap in middle" $ do
            ranges <- runMem $ do
                forM_ [0..6] $ \i -> do
                    let day = addDaysT' (i - 6) "2024-01-10"
                    when (day /= "2024-01-07" && day /= "2024-01-08") $
                        upsertDailyMetric Sleep day (Just 80) (obj ["day" .= day])
                backfillRanges (Daily Sleep) 7 "2024-01-10"
            ranges `shouldBe` [DateRange "2024-01-07" "2024-01-08", DateRange "2024-01-10" "2024-01-10"]

        it "heartrate always full window" $ do
            ranges <- runMem $ do
                forM_ [0..6] $ \i -> do
                    let day = addDaysT' (i - 6) "2024-01-10"
                    when (day /= "2024-01-09") $
                        insertHr (unDayText day <> "T00:00:00") 60 day
                backfillRanges HeartrateSeries 7 "2024-01-10"
            ranges `shouldBe` [DateRange "2024-01-04" "2024-01-10"]

    describe "run_sync with backfill" $ do
        it "fetches missing days" $ do
            (calls, result) <- runMem $ do
                forM_ [0..6] $ \i -> do
                    let day = addDaysT' (i - 6) "2024-01-10"
                    when (day /= "2024-01-08") $
                        upsertDailyMetric Sleep day (Just 80) (obj ["day" .= day])
                updateSyncLog (Daily Sleep) "2024-01-09"
                ref <- newIORef []
                res <- runSync "2024-01-10" (stubClient ref
                        [ obj ["day" .= ("2024-01-08" :: Text), "score" .= (75 :: Int)]
                        , obj ["day" .= ("2024-01-10" :: Text), "score" .= (80 :: Int)] ] [])
                        Nothing Nothing (Just [Daily Sleep]) 7
                cs <- readIORef ref
                return (cs, res)
            let ranges = callsFor "sleep" calls
            ranges `shouldSatisfy` elem (DateRange "2024-01-10" "2024-01-10")
            ranges `shouldSatisfy` elem (DateRange "2024-01-08" "2024-01-08")
            M.findWithDefault 0 (Daily Sleep) (syncedCounts result) `shouldSatisfy` (> 0)

        -- Without backfill there is a single incremental call. Because the
        -- refetch window (today-6) reaches back to cover the gap, the whole
        -- window is fetched as one range — the Python assertion expecting only
        -- (today, today) was unreachable (update_sync_log raised first).
        it "no backfill fetches only the incremental refetch window" $ do
            calls <- runMem $ do
                forM_ [0..6] $ \i -> do
                    let day = addDaysT' (i - 6) "2024-01-10"
                    when (day /= "2024-01-08") $
                        upsertDailyMetric Sleep day (Just 80) (obj ["day" .= day])
                updateSyncLog (Daily Sleep) "2024-01-09"
                ref <- newIORef []
                _ <- runSync "2024-01-10" (stubClient ref
                        [obj ["day" .= ("2024-01-10" :: Text), "score" .= (80 :: Int)]] [])
                        Nothing Nothing (Just [Daily Sleep]) 0
                readIORef ref
            callsFor "sleep" calls `shouldBe` [DateRange "2024-01-04" "2024-01-10"]

-- helpers ----------------------------------------------------------------

fieldOf :: Text -> A.Value -> Maybe A.Value
fieldOf k (A.Object o) = KM.lookup (K.fromText k) o
fieldOf _ _            = Nothing

insertHr :: (MonadIO m) => Text -> Int -> DayText -> SqlPersistT m ()
insertHr ts bpm day = rawExecute
    "INSERT INTO heartrate (timestamp, bpm, day) VALUES (?, ?, ?)"
    [toPersistValue ts, toPersistValue bpm, toPersistValue day]

-- | Add an Int day offset to a day.
addDaysT' :: Int -> DayText -> DayText
addDaysT' n = addDaysT (fromIntegral n)

-- | Day difference end - start (as Integer) for the 30-day window assertion.
diffDaysT :: DayText -> DayText -> Integer
diffDaysT end start = diffDays (parseDay end) (parseDay start)
