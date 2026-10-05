{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The health payload the advice prompt is built from. The claude CLI call
-- itself is covered by the handler tests; this only pins the JSON handed to it.
module AdviceSpec (spec) where

import ClassyPrelude
import Test.Hspec
import Database.Persist.Sqlite (runSqlite, runMigrationSilent)
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM

import Advice (buildHealthPayload)
import Db (upsertSleepPeriods)
import Model (migrateAll)

-- | A fresh in-memory database per call. Signature left to inference to avoid
-- naming the ResourceT/NoLoggingT stack runSqlite fixes internally.
runMem action = runSqlite ":memory:" $ do
    _ <- runMigrationSilent migrateAll
    action

field :: Text -> A.Value -> Maybe A.Value
field k (A.Object o) = KM.lookup (K.fromText k) o
field _ _            = Nothing

-- | A period contributing the given stage durations, in seconds.
period :: Text -> Text -> Int -> Int -> Int -> Int -> A.Value
period = periodOfType "long_sleep"

periodOfType :: Text -> Text -> Text -> Int -> Int -> Int -> Int -> A.Value
periodOfType sleepType ouraId day deep light rem' awake = A.object
    [ "id" .= ouraId, "day" .= day, "type" .= sleepType
    , "bedtime_start" .= (day <> "T01:00:00+09:00")
    , "bedtime_end" .= (day <> "T08:00:00+09:00")
    , "deep_sleep_duration" .= deep
    , "light_sleep_duration" .= light
    , "rem_sleep_duration" .= rem'
    , "awake_time" .= awake
    , "total_sleep_duration" .= (deep + light + rem')
    , "time_in_bed" .= (deep + light + rem' + awake)
    ]

spec :: Spec
spec = do
    describe "build_health_payload" $ do
        it "includes sleep_periods" $ do
            payload <- runMem $ do
                _ <- upsertSleepPeriods [period "a" "2024-01-10" 3000 14000 7000 3600]
                buildHealthPayload "2024-01-10" 14
            let rows = field "sleep_periods" payload
            case rows of
                Just (A.Array v) -> do
                    length v `shouldBe` 1
                    let row = headEx (toList v)
                    field "day" row `shouldBe` Just (A.String "2024-01-10")
                    field "deep_sleep_duration" row `shouldBe` Just (A.Number 3000)
                    field "time_in_bed" row `shouldBe` Just (A.Number 27600)
                _ -> expectationFailure "sleep_periods is not an array"

        it "sums the periods of one day" $ do
            payload <- runMem $ do
                _ <- upsertSleepPeriods
                    [ period "a" "2024-01-10" 3000 14000 7000 3600
                    , period "b" "2024-01-10"  100   800   200  300 ]
                buildHealthPayload "2024-01-10" 14
            case field "sleep_periods" payload of
                Just (A.Array v) -> do
                    length v `shouldBe` 1
                    field "light_sleep_duration" (headEx (toList v))
                        `shouldBe` Just (A.Number 14800)
                _ -> expectationFailure "sleep_periods is not an array"

        it "is an empty array before the first sync" $ do
            payload <- runMem $ buildHealthPayload "2024-01-10" 14
            field "sleep_periods" payload `shouldBe` Just (A.Array mempty)

        it "keeps rest periods out of the prompt" $ do
            payload <- runMem $ do
                _ <- upsertSleepPeriods
                    [ periodOfType "rest" "a" "2024-01-10" 3000 14000 7000 3600 ]
                buildHealthPayload "2024-01-10" 14
            field "sleep_periods" payload `shouldBe` Just (A.Array mempty)

    describe "build_health_payload sleep times" $ do
        let timed sleepType ouraId start end tib latency = A.object
                [ "id" .= (ouraId :: Text), "day" .= ("2024-01-10" :: Text)
                , "type" .= (sleepType :: Text)
                , "bedtime_start" .= (start :: Text), "bedtime_end" .= (end :: Text)
                , "time_in_bed" .= (tib :: Int), "latency" .= (latency :: Int) ]
            row periods = do
                payload <- runMem $ do
                    _ <- upsertSleepPeriods periods
                    buildHealthPayload "2024-01-10" 14
                case field "sleep_periods" payload of
                    Just (A.Array v) | [r] <- toList v -> return r
                    _ -> expectationFailure "expected one sleep_periods row" >> return A.Null

        it "takes the clock times from the long sleep and counts the rest as naps" $ do
            r <- row
                [ timed "long_sleep" "a" "2024-01-09T23:41:00+09:00" "2024-01-10T07:05:00+09:00" 26640 1140
                , timed "late_nap" "b" "2024-01-10T14:05:00+09:00" "2024-01-10T14:40:00+09:00" 2100 300 ]
            field "bedtime_start" r `shouldBe` Just (A.String "23:41")
            field "sleep_onset" r `shouldBe` Just (A.String "00:00")
            field "bedtime_end" r `shouldBe` Just (A.String "07:05")
            field "naps" r `shouldBe` Just (A.Number 1)
            field "nap_time_in_bed" r `shouldBe` Just (A.Number 2100)

        it "keeps the wall clock of the recorded offset" $ do
            r <- row [ timed "long_sleep" "a" "2024-01-09T22:30:00.000-05:00" "2024-01-10T06:00:00.000-05:00" 27000 0 ]
            field "bedtime_start" r `shouldBe` Just (A.String "22:30")
            field "bedtime_end" r `shouldBe` Just (A.String "06:00")

        it "falls back to the longest period without a long sleep" $ do
            r <- row
                [ timed "sleep" "a" "2024-01-10T01:00:00+09:00" "2024-01-10T02:00:00+09:00" 3600 0
                , timed "sleep" "b" "2024-01-10T03:00:00+09:00" "2024-01-10T08:00:00+09:00" 18000 600 ]
            field "bedtime_start" r `shouldBe` Just (A.String "03:00")
            field "sleep_onset" r `shouldBe` Just (A.String "03:10")
            field "naps" r `shouldBe` Just (A.Number 1)
            field "nap_time_in_bed" r `shouldBe` Just (A.Number 3600)

        it "leaves the clock times empty on a day with a late nap only" $ do
            r <- row [ timed "late_nap" "a" "2024-01-09T18:27:00+09:00" "2024-01-09T19:20:00+09:00" 3180 0 ]
            field "bedtime_start" r `shouldBe` Just A.Null
            field "bedtime_end" r `shouldBe` Just A.Null
            field "naps" r `shouldBe` Just (A.Number 1)
