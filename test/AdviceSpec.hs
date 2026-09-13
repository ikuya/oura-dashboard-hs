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
