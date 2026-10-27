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

import Advice (adviceComparison, buildAdvicePrompt, buildHealthPayload)
import DateText (DateRange (..))
import Db (SavedAdvice (..), replaceEvents, upsertDailyMetric, upsertSleepPeriods)
import Metric (DailyMetric (..), EventKind (..))
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
    , "sleep_score_delta" .= (1 :: Int)
    ]

previousAdvice :: SavedAdvice
previousAdvice = SavedAdvice "2024-01-08T02:30:00+00:00"
    (DateRange "2023-12-26" "2024-01-08") "### 💡 アドバイス\n- 早く寝る"

spec :: Spec
spec = do
    describe "build_advice_prompt" $ do
        it "asks for no follow-up without a previous advice" $ do
            let prompt = buildAdvicePrompt Nothing (A.object [])
            prompt `shouldNotSatisfy` isInfixOf "前回"
            prompt `shouldNotSatisfy` isInfixOf "<previous_advice"

        it "appends the previous advice and asks what changed since" $ do
            let prompt = buildAdvicePrompt (Just previousAdvice) (A.object [])
            prompt `shouldSatisfy` isInfixOf "### 🔁 前回からの変化"
            prompt `shouldSatisfy` isInfixOf
                "<previous_advice saved_at=\"2024-01-08T02:30:00+00:00\" period=\"2023-12-26..2024-01-08\">\n### 💡 アドバイス\n- 早く寝る\n</previous_advice>"

    describe "advice_comparison" $ do
        let scores c = case field "scores" c of
                Just (A.Array v) -> toList v
                _                -> []
            score m c = find ((== Just (A.String m)) . field "metric") (scores c)

        it "sets each score's period mean beside the previous period's" $ do
            c <- runMem $ do
                upsertDailyMetric Readiness "2024-01-05" (Just 60) (A.object [])
                upsertDailyMetric Readiness "2024-01-10" (Just 80) (A.object [])
                upsertDailyMetric Readiness "2024-01-12" (Just 90) (A.object [])
                adviceComparison (DateRange "2024-01-09" "2024-01-22") (Just previousAdvice)
            map (field "metric") (scores c) `shouldBe`
                map (Just . A.String) ["readiness", "sleep", "activity"]
            (field "average" =<< score "readiness" c) `shouldBe` Just (A.Number 85)
            (field "previous" =<< score "readiness" c) `shouldBe` Just (A.Number 60)
            (field "average" =<< score "sleep" c) `shouldBe` Just A.Null
            (field "saved_at" =<< field "previous" c)
                `shouldBe` Just (A.String "2024-01-08T02:30:00+00:00")

        it "has no previous means without a previous advice" $ do
            c <- runMem $ do
                upsertDailyMetric Readiness "2024-01-10" (Just 80) (A.object [])
                adviceComparison (DateRange "2024-01-09" "2024-01-22") Nothing
            field "previous" c `shouldBe` Just A.Null
            (field "previous" =<< score "readiness" c) `shouldBe` Just A.Null

    describe "build_health_payload" $ do
        it "includes sleep_periods" $ do
            payload <- runMem $ do
                _ <- upsertSleepPeriods [period "a" "2024-01-10" 3000 14000 7000 3600]
                buildHealthPayload "2024-01-10"
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
                buildHealthPayload "2024-01-10"
            case field "sleep_periods" payload of
                Just (A.Array v) -> do
                    length v `shouldBe` 1
                    field "light_sleep_duration" (headEx (toList v))
                        `shouldBe` Just (A.Number 14800)
                _ -> expectationFailure "sleep_periods is not an array"

        it "is an empty array before the first sync" $ do
            payload <- runMem $ buildHealthPayload "2024-01-10"
            field "sleep_periods" payload `shouldBe` Just (A.Array mempty)

        it "keeps rest periods out of the prompt" $ do
            payload <- runMem $ do
                _ <- upsertSleepPeriods
                    [ periodOfType "rest" "a" "2024-01-10" 3000 14000 7000 3600 ]
                buildHealthPayload "2024-01-10"
            field "sleep_periods" payload `shouldBe` Just (A.Array mempty)

    describe "build_health_payload events" $ do
        it "summarises the tags and workouts of the period" $ do
            payload <- runMem $ do
                _ <- replaceEvents Tags (DateRange "2024-01-01" "2024-01-10")
                    [ A.object [ "id" A..= ("t" :: Text), "start_day" A..= ("2024-01-09" :: Text)
                               , "tag_type_code" A..= ("tag_sleep_alcohol" :: Text)
                               , "start_time" A..= ("2024-01-09T21:00:09+09:00" :: Text) ] ]
                _ <- replaceEvents Workouts (DateRange "2024-01-01" "2024-01-10")
                    [ A.object [ "id" A..= ("w" :: Text), "day" A..= ("2024-01-09" :: Text)
                               , "activity" A..= ("walking" :: Text), "calories" A..= (64.4 :: Double)
                               , "start_datetime" A..= ("2024-01-09T21:18:00.000+09:00" :: Text)
                               , "end_datetime" A..= ("2024-01-09T21:58:00.000+09:00" :: Text) ] ]
                buildHealthPayload "2024-01-10"
            let only k = case field k payload of
                    Just (A.Array v) | [x] <- toList v -> return x
                    _ -> expectationFailure (unpack k <> " is not a one-element array") >> return A.Null
            tag <- only "tags"
            field "tag" tag `shouldBe` Just (A.String "tag_sleep_alcohol")
            field "time" tag `shouldBe` Just (A.String "21:00")
            workout <- only "workouts"
            field "minutes" workout `shouldBe` Just (A.Number 40)
            field "calories" workout `shouldBe` Just (A.Number 64)
            field "start" workout `shouldBe` Just (A.String "21:18")
            field "sessions" payload `shouldBe` Just (A.Array mempty)

    describe "build_health_payload sleep times" $ do
        let timed sleepType ouraId start end tib latency = A.object
                [ "id" .= (ouraId :: Text), "day" .= ("2024-01-10" :: Text)
                , "type" .= (sleepType :: Text)
                , "bedtime_start" .= (start :: Text), "bedtime_end" .= (end :: Text)
                , "time_in_bed" .= (tib :: Int), "latency" .= (latency :: Int)
                , "sleep_score_delta" .= (1 :: Int) ]
            row periods = do
                payload <- runMem $ do
                    _ <- upsertSleepPeriods periods
                    buildHealthPayload "2024-01-10"
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

        it "takes the vitals from the main period, not a nap" $ do
            let withVitals hrv lowest p = case p of
                    A.Object o -> A.Object (KM.insert "average_hrv" (A.Number hrv)
                                            (KM.insert "lowest_heart_rate" (A.Number lowest) o))
                    other -> other
            r <- row
                [ withVitals 45 52 (timed "long_sleep" "a" "2024-01-09T23:41:00+09:00" "2024-01-10T07:05:00+09:00" 26640 1140)
                , withVitals 30 60 (timed "late_nap" "b" "2024-01-10T14:05:00+09:00" "2024-01-10T14:40:00+09:00" 2100 300) ]
            field "average_hrv" r `shouldBe` Just (A.Number 45)
            field "lowest_heart_rate" r `shouldBe` Just (A.Number 52)
            field "average_breath" r `shouldBe` Just A.Null

        it "leaves the clock times empty on a day with a late nap only" $ do
            r <- row [ timed "late_nap" "a" "2024-01-09T18:27:00+09:00" "2024-01-09T19:20:00+09:00" 3180 0 ]
            field "bedtime_start" r `shouldBe` Just A.Null
            field "bedtime_end" r `shouldBe` Just A.Null
            field "naps" r `shouldBe` Just (A.Number 1)
