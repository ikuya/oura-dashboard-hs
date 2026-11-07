{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase        #-}

-- | The metrics the dashboard tracks.
--
-- A type rather than bare strings compared with @==@ across the sync, DB and
-- handler layers: the compiler checks that every dispatch table is total, the
-- wire names live in one place, and "heartrate is not a daily metric" is in
-- the type rather than checked by hand.
module Metric
    ( DailyMetric (..)
    , EventKind (..)
    , Metric (..)
    , dailyMetricName
    , eventKindName
    , allEventKinds
    , parseDailyMetric
    , metricName
    , allDailyMetrics
    , dashboardMetrics
    , syncTargets
    , syncStatusMetrics
    , seriesMetrics
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
      -- ^ Reported by @getSyncStatus@, but the sync never fetches it.
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | The user's own records of a day: tags (alcohol, caffeine, ...), workouts
-- and guided sessions. Any number per day, keyed by Oura document id, and all
-- kept in @oura_events@.
data EventKind
    = Tags
    | Workouts
    | Sessions
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | A sync/report target: a daily metric, or one of the series that live in
-- their own tables rather than one row per day. (The @Series@ suffix avoids a
-- clash with the persistent entities @Heartrate@ and @SleepPeriod@.)
data Metric
    = Daily DailyMetric
    | HeartrateSeries
    | SleepPeriodSeries
      -- ^ Sleep period documents: several per day, keyed by Oura document id.
    | EventSeries EventKind
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

-- | The name used in the @oura_events.kind@ column and the JSON API.
eventKindName :: EventKind -> Text
eventKindName = \case
    Tags     -> "tags"
    Workouts -> "workouts"
    Sessions -> "sessions"

allEventKinds :: [EventKind]
allEventKinds = [minBound .. maxBound]

metricName :: Metric -> Text
metricName (Daily m)         = dailyMetricName m
metricName HeartrateSeries   = "heartrate"
metricName SleepPeriodSeries = "sleep_periods"
metricName (EventSeries k)   = eventKindName k

parseDailyMetric :: Text -> Maybe DailyMetric
parseDailyMetric name =
    lookup name [ (dailyMetricName m, m) | m <- allDailyMetrics ]

-- | Every daily metric, in display order.
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
        ++ seriesMetrics

-- | The metrics @Db.getSyncStatus@ reports on.
syncStatusMetrics :: [Metric]
syncStatusMetrics = map Daily allDailyMetrics ++ seriesMetrics

-- | Every target that is not a daily metric.
seriesMetrics :: [Metric]
seriesMetrics =
    [HeartrateSeries, SleepPeriodSeries] ++ map EventSeries allEventKinds
