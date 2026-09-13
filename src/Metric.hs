{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase        #-}

-- | The metrics the dashboard tracks.
--
-- The Python port carried these as bare strings and dispatched on them with
-- @==@ throughout the sync, DB and handler layers. As a type, the compiler
-- checks that every dispatch table is total, the wire names live in one place,
-- and the "heartrate is not a daily metric" distinction the code kept making
-- by hand is in the type instead.
module Metric
    ( DailyMetric (..)
    , Metric (..)
    , dailyMetricName
    , parseDailyMetric
    , metricName
    , allDailyMetrics
    , dashboardMetrics
    , syncTargets
    , syncStatusMetrics
    ) where

import ClassyPrelude

-- | A metric stored as one row per day in @daily_metrics@.
data DailyMetric
    = Sleep
    | Readiness
    | Activity
    | Stress
    | Spo2
    | Resilience
    | CardiovascularAge
    | Temperature
      -- ^ Derived from the readiness payload; never fetched on its own.
    | VO2Max
      -- ^ Reported by @get_sync_status@, but the sync never fetches it.
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | A sync/report target: a daily metric, or one of the two series that live
-- in their own tables rather than one row per day. (The @Series@ suffix avoids
-- a clash with the persistent entities @Heartrate@ and @SleepPeriod@.)
data Metric
    = Daily DailyMetric
    | HeartrateSeries
    | SleepPeriodSeries
      -- ^ Sleep period documents: several per day, keyed by Oura document id.
    deriving (Eq, Ord, Show)

-- | The name used in the DB @metric@ column, the JSON API and the Oura API.
dailyMetricName :: DailyMetric -> Text
dailyMetricName = \case
    Sleep             -> "sleep"
    Readiness         -> "readiness"
    Activity          -> "activity"
    Stress            -> "stress"
    Spo2              -> "spo2"
    Resilience        -> "resilience"
    CardiovascularAge -> "cardiovascular_age"
    Temperature       -> "temperature"
    VO2Max            -> "vo2_max"

metricName :: Metric -> Text
metricName (Daily m)         = dailyMetricName m
metricName HeartrateSeries   = "heartrate"
metricName SleepPeriodSeries = "sleep_periods"

parseDailyMetric :: Text -> Maybe DailyMetric
parseDailyMetric name =
    lookup name [ (dailyMetricName m, m) | m <- allDailyMetrics ]

-- | Every daily metric, in the order the Python lists used.
allDailyMetrics :: [DailyMetric]
allDailyMetrics = [minBound .. maxBound]

-- | The metrics the dashboard serves and feeds to the advice prompt: every
-- daily metric the sync actually stores, so not vO2 max.
dashboardMetrics :: [DailyMetric]
dashboardMetrics = filter (/= VO2Max) allDailyMetrics

-- | What a sync with no explicit metric list covers. Temperature is derived
-- from readiness and vO2 max is not synced, so neither is a target.
syncTargets :: [Metric]
syncTargets =
    map Daily (filter (`notElem` [Temperature, VO2Max]) allDailyMetrics)
        ++ [HeartrateSeries, SleepPeriodSeries]

-- | The metrics @get_sync_status@ reports on.
syncStatusMetrics :: [Metric]
syncStatusMetrics =
    map Daily allDailyMetrics ++ [HeartrateSeries, SleepPeriodSeries]
