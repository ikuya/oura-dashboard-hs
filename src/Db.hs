{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

-- | Database layer, ported from the Python app's db.py.
--
-- Query functions that merge the opaque @data_json@ blob with the @day@/@score@
-- columns return aeson 'Value's (matching the Python dicts), so the JSON API
-- contract stays byte-compatible. Raw SQL is used where the Python code relies
-- on @INSERT OR REPLACE@, @INSERT OR IGNORE@, @substr()@ or @GROUP BY@, keeping
-- those queries 1:1 with the original.
module Db where

import ClassyPrelude.Yesod
import qualified Data.Aeson          as A
import qualified Data.Aeson.Key      as K
import qualified Data.Aeson.KeyMap   as KM
import qualified Data.Map.Strict     as M
import Data.Monoid                (Sum (..))
import Database.Persist.Sql       (rawExecute, rawSql, Single (..))

import DateText
import Json                       (jsonDouble, jsonInt, jsonLookup, jsonText)
import Metric

-- | Current UTC time as an ISO-8601 string, matching Python's
-- @datetime.now(timezone.utc).isoformat()@ which yields e.g.
-- @2026-04-12T04:00:26.448555+00:00@ (microseconds, +00:00 offset).
nowIso :: MonadIO m => m Text
nowIso = formatUtc <$> liftIO getCurrentTime
  where
    formatUtc = pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%6Q+00:00"

-- | Parse a stored @data_json@ string into an aeson Object. A row that fails to
-- parse (should not happen for our data) yields an empty object.
parseDataJson :: Text -> A.Object
parseDataJson t = case A.decodeStrict (encodeUtf8 t) of
    Just (A.Object o) -> o
    _                 -> KM.empty

-- | Merge day/score onto the parsed data_json object. The DB @score@ column
-- takes precedence over any @score@ inside data_json (mirrors db.py's
-- @{**data, "day": ..., "score": ...}@).
mergeRow :: DayText -> Maybe Double -> A.Object -> A.Value
mergeRow day mscore o =
    A.Object $ KM.insert "score" (maybe A.Null A.toJSON mscore)
             $ KM.insert "day" (A.toJSON day) o

-- upsert_daily_metric
upsertDailyMetric
    :: (MonadIO m)
    => DailyMetric -> DayText -> Maybe Double -> A.Value -> ReaderT SqlBackend m ()
upsertDailyMetric metric day score dataObj = do
    now <- nowIso
    let dataText = decodeUtf8 (toStrict (A.encode dataObj))
    rawExecute
        "INSERT OR REPLACE INTO daily_metrics (metric, day, score, data_json, synced_at) VALUES (?, ?, ?, ?, ?)"
        [ toPersistValue (dailyMetricName metric)
        , toPersistValue day
        , toPersistValue score
        , toPersistValue dataText
        , toPersistValue now
        ]

-- upsert_heartrate_batch: skips records missing timestamp or bpm; day = ts[:10].
-- Returns the number of records processed (matching Python's count).
upsertHeartrateBatch
    :: (MonadIO m) => [(Text, Maybe Int)] -> ReaderT SqlBackend m Int
upsertHeartrateBatch records = do
    let valid = [ (ts, bpm) | (ts, Just bpm) <- records, not (null ts) ]
    forM_ valid $ \(ts, bpm) ->
        rawExecute
            "INSERT OR IGNORE INTO heartrate (timestamp, bpm, day) VALUES (?, ?, ?)"
            [ toPersistValue ts
            , toPersistValue bpm
            , toPersistValue (take 10 ts)
            ]
    return (length valid)

-- update_sync_log
updateSyncLog :: (MonadIO m) => Metric -> DayText -> ReaderT SqlBackend m ()
updateSyncLog metric lastDay = do
    now <- nowIso
    rawExecute
        "INSERT OR REPLACE INTO sync_log (metric, last_synced_day, last_synced_at) VALUES (?, ?, ?)"
        [toPersistValue (metricName metric), toPersistValue lastDay, toPersistValue now]

-- get_last_synced_day
getLastSyncedDay :: (MonadIO m) => Metric -> ReaderT SqlBackend m (Maybe DayText)
getLastSyncedDay metric = do
    rows <- rawSql
        "SELECT last_synced_day FROM sync_log WHERE metric = ?"
        [toPersistValue (metricName metric)]
    return $ unSingle <$> headMay rows

-- get_daily_metrics
getDailyMetrics
    :: (MonadIO m) => DailyMetric -> DateRange -> ReaderT SqlBackend m [A.Value]
getDailyMetrics metric (DateRange start end) = do
    rows <- rawSql
        "SELECT day, score, data_json FROM daily_metrics WHERE metric = ? AND day >= ? AND day <= ? ORDER BY day"
        [toPersistValue (dailyMetricName metric), toPersistValue start, toPersistValue end]
    return [ mergeRow day score (parseDataJson dj)
           | (Single day, Single score, Single dj) <- rows ]

-- get_daily_metrics_bulk
getDailyMetricsBulk
    :: (MonadIO m)
    => [DailyMetric] -> DateRange
    -> ReaderT SqlBackend m (Map DailyMetric [A.Value])
getDailyMetricsBulk metrics (DateRange start end)
    | null metrics = return mempty
    | otherwise = do
        let placeholders = intercalate "," (map (const "?") metrics)
            sql = "SELECT metric, day, score, data_json FROM daily_metrics WHERE metric IN ("
                  <> placeholders
                  <> ") AND day >= ? AND day <= ? ORDER BY metric, day"
        rows <- rawSql sql
            (map (toPersistValue . dailyMetricName) metrics
                ++ [toPersistValue start, toPersistValue end])
        -- The query is ordered by (metric, day) and @flip (++)@ appends, so
        -- each metric keeps its rows in day order. Union with the all-metrics
        -- map (left-biased) gives metrics without rows an empty list.
        let byMetric = M.fromListWith (flip (++))
                [ (metric, [mergeRow day score (parseDataJson dj)])
                | (Single name, Single day, Single score, Single dj) <- rows
                , Just metric <- [parseDailyMetric name] ]
        return $ M.union byMetric (M.fromList [ (m, []) | m <- metrics ])

-- get_heartrate
getHeartrate
    :: (MonadIO m) => DateRange -> ReaderT SqlBackend m [A.Value]
getHeartrate (DateRange start end) = do
    rows <- rawSql
        "SELECT timestamp, bpm FROM heartrate WHERE day >= ? AND day <= ? ORDER BY timestamp"
        [toPersistValue start, toPersistValue end]
    return [ A.object ["timestamp" A..= (ts :: Text), "bpm" A..= (bpm :: Int)]
           | (Single ts, Single bpm) <- rows ]

-- sleep periods ----------------------------------------------------------

-- | The fields of a sleep period the JSON API exposes. A stored record is
-- ~3KB, most of it the 30-second phase and movement strings that no chart
-- reads, so reads project it down. The 5-minute @hrv@ / @heart_rate@ series
-- the hypnogram overlays are the bulk of what is left. The whole record stays
-- in @data_json@, so widening this list later needs no re-sync.
sleepPeriodFields :: [Text]
sleepPeriodFields =
    [ "id", "day", "type", "period"
    , "bedtime_start", "bedtime_end"
    , "sleep_phase_5_min"
    , "deep_sleep_duration", "light_sleep_duration", "rem_sleep_duration"
    , "awake_time", "total_sleep_duration", "time_in_bed"
    , "efficiency", "latency"
    , "average_hrv", "average_heart_rate", "lowest_heart_rate", "average_breath"
    , "hrv", "heart_rate"
    ]

-- | Period types the charts ignore: @deleted@ is the tombstone for a sleep the
-- user removed, and @rest@ is a detection the user rejected as "not asleep"
-- (Oura leaves it out of the daily scores too).
hiddenSleepTypes :: [Text]
hiddenSleepTypes = ["deleted", "rest"]

-- | SQL condition keeping the periods the Oura app counts as sleep. The API
-- also returns short detections (mostly a few minutes asleep) that the app
-- shows neither as a nap nor in the day's totals; those are the ones whose
-- @sleep_score_delta@ is null. A long sleep always counts: older records and
-- a night not yet scored carry a null delta too.
countedSleepCondition :: Text
countedSleepCondition =
    "(type = 'long_sleep' OR json_extract(data_json, '$.sleep_score_delta') IS NOT NULL)"

-- | New in the Haskell port. Skips records without an id or day. Keyed on
-- the Oura document id rather than the day, because one day holds several
-- periods (a long sleep plus naps). Returns the number of records written.
upsertSleepPeriods :: (MonadIO m) => [A.Value] -> ReaderT SqlBackend m Int
upsertSleepPeriods records = do
    now <- nowIso
    let valid = [ (ouraId, day, r)
                | r <- records
                , Just ouraId <- [jsonText =<< jsonLookup "id" r]
                , Just day    <- [jsonText =<< jsonLookup "day" r] ]
    forM_ valid $ \(ouraId, day, r) ->
        rawExecute
            "INSERT OR REPLACE INTO sleep_periods (id, day, bedtime_start, bedtime_end, type, data_json, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
            [ toPersistValue ouraId
            , toPersistValue day
            , toPersistValue (strOrEmpty "bedtime_start" r)
            , toPersistValue (strOrEmpty "bedtime_end" r)
            , toPersistValue (strOrEmpty "type" r)
            , toPersistValue (decodeUtf8 (toStrict (A.encode r)))
            , toPersistValue now
            ]
    return (length valid)
  where
    strOrEmpty k r = fromMaybe "" (jsonText =<< jsonLookup k r)

-- | New in the Haskell port. Ordered by bedtime_start so the periods of one
-- night come back in the order they happened, whatever their @period@ index says.
getSleepPeriods
    :: (MonadIO m) => DateRange -> ReaderT SqlBackend m [A.Value]
getSleepPeriods (DateRange start end) = do
    rows <- rawSql
        ("SELECT data_json FROM sleep_periods WHERE day >= ? AND day <= ? AND type NOT IN ("
            <> intercalate "," (map (const "?") hiddenSleepTypes)
            <> ") AND " <> countedSleepCondition <> " ORDER BY bedtime_start")
        ([toPersistValue start, toPersistValue end]
            ++ map toPersistValue hiddenSleepTypes)
    return [ projectSleepPeriod (parseDataJson dj) | Single dj <- rows ]

-- | Narrow a stored record to 'sleepPeriodFields'.
projectSleepPeriod :: A.Object -> A.Value
projectSleepPeriod =
    A.Object . KM.filterWithKey (\k _ -> K.toText k `elem` sleepPeriodFields)

-- | The long sleep if the day has one, otherwise its longest period by time in
-- bed (the first of equals). A late nap is never the night's sleep, so a day
-- holding nothing else has no main period. Mirrors @mainPeriod@ in
-- static/helpers.js.
mainSleepPeriod :: [A.Value] -> Maybe A.Value
mainSleepPeriod rows =
    find ((== Just "long_sleep") . sleepType) candidates
        <|> headMay (sortOn (Down . periodSeconds "time_in_bed") candidates)
  where
    sleepType = jsonText <=< jsonLookup "type"
    candidates = filter ((/= Just "late_nap") . sleepType) rows

periodSeconds :: Text -> A.Value -> Int
periodSeconds f r = fromMaybe 0 (jsonInt =<< jsonLookup f r)

-- events ------------------------------------------------------------------

-- | The day an event record is filed under: the day it starts on. Tags carry
-- a start_day (and an optional end_day) rather than a day.
eventDay :: EventKind -> A.Value -> Maybe DayText
eventDay kind r = DayText <$> (jsonText =<< jsonLookup field r)
  where
    field = case kind of
        Tags     -> "start_day"
        Workouts -> "day"
        Sessions -> "day"

-- | Store the events of one kind fetched for a range, replacing what the range
-- held before. A tag deleted in the Oura app is simply missing from the next
-- fetch, so upserting alone would keep it forever. The fetch returns the
-- events starting on the range's days, the same ones the delete covers.
-- Skips records without an id or day; returns the number written.
replaceEvents
    :: (MonadIO m) => EventKind -> DateRange -> [A.Value] -> ReaderT SqlBackend m Int
replaceEvents kind (DateRange start end) records = do
    now <- nowIso
    rawExecute
        "DELETE FROM oura_events WHERE kind = ? AND day >= ? AND day <= ?"
        [toPersistValue (eventKindName kind), toPersistValue start, toPersistValue end]
    let valid = [ (ouraId, day, r)
                | r <- records
                , Just ouraId <- [jsonText =<< jsonLookup "id" r]
                , Just day    <- [eventDay kind r] ]
    forM_ valid $ \(ouraId, day, r) ->
        rawExecute
            "INSERT OR REPLACE INTO oura_events (kind, id, day, data_json, synced_at) VALUES (?, ?, ?, ?, ?)"
            [ toPersistValue (eventKindName kind)
            , toPersistValue ouraId
            , toPersistValue day
            , toPersistValue (decodeUtf8 (toStrict (A.encode r)))
            , toPersistValue now
            ]
    return (length valid)

-- | The fields left out of event reads: a session's 5-second heart rate, HRV
-- and motion series, which nothing draws.
eventSeriesFields :: [Text]
eventSeriesFields = ["heart_rate", "heart_rate_variability", "motion_count"]

-- | The events of one kind touching the range, in the order they started. A
-- tag spanning several days counts from its start_day through its end_day,
-- so one that began before the range still shows.
getEvents
    :: (MonadIO m) => EventKind -> DateRange -> ReaderT SqlBackend m [A.Value]
getEvents kind (DateRange start end) = do
    rows <- rawSql
        "SELECT data_json FROM oura_events WHERE kind = ? AND day <= ? AND COALESCE(json_extract(data_json, '$.end_day'), day) >= ? ORDER BY day, COALESCE(json_extract(data_json, '$.start_time'), json_extract(data_json, '$.start_datetime'))"
        [toPersistValue (eventKindName kind), toPersistValue end, toPersistValue start]
    return [ A.Object (KM.filterWithKey (\k _ -> K.toText k `notElem` eventSeriesFields)
                                        (parseDataJson dj))
           | Single dj <- rows ]

-- | Every kind of event touching the range, keyed by kind name.
getAllEvents :: (MonadIO m) => DateRange -> ReaderT SqlBackend m (Map Text [A.Value])
getAllEvents range = M.fromList <$>
    forM allEventKinds (\k -> (,) (eventKindName k) <$> getEvents k range)

-- monthly means -----------------------------------------------------------

-- | The series of the long-term view that are one value per row of a daily
-- metric: the name it is served under, the metric, and the SQL expression
-- for the value.
monthlyDailySeries :: [(Text, DailyMetric, Text)]
monthlyDailySeries =
    [ ("readiness", Readiness, "score")
    , ("sleep", Sleep, "score")
    , ("activity", Activity, "score")
    , ("steps", Activity, "json_extract(data_json, '$.steps')")
    , ("stress_high", Stress, "json_extract(data_json, '$.stress_high')")
    ]

-- | The per-night vitals of the long-term view, read off each day's main
-- sleep period.
monthlySleepFields :: [Text]
monthlySleepFields = ["average_hrv", "lowest_heart_rate"]

-- | Each calendar month's mean of the given daily values, with the number of
-- days behind it, in month order.
monthlyMeans :: [(DayText, Double)] -> [A.Value]
monthlyMeans values =
    [ A.object ["month" A..= month, "mean" A..= (total / fromIntegral n), "days" A..= n]
    | (month, (Sum total, Sum n)) <- M.toList byMonth ]
  where
    byMonth :: Map Text (Sum Double, Sum Int)
    byMonth = M.fromListWith (<>)
        [ (take 7 (unDayText day), (Sum v, Sum 1)) | (day, v) <- values ]

-- | The monthly means of every series of the long-term view over all stored
-- days, keyed by series name. A month without a value for a series is absent
-- from its list.
getMonthlyMeans :: (MonadIO m) => ReaderT SqlBackend m (Map Text [A.Value])
getMonthlyMeans = do
    daily <- forM monthlyDailySeries $ \(name, metric, expr) -> do
        rows <- rawSql
            ("SELECT day, CAST(" <> expr <> " AS REAL) FROM daily_metrics WHERE metric = ? AND "
                <> expr <> " IS NOT NULL")
            [toPersistValue (dailyMetricName metric)]
        return (name, monthlyMeans [ (day, v) | (Single day, Single v) <- rows ])
    nights <- mainSleepPeriods
    let vitals = [ (f, monthlyMeans [ (day, v) | (day, p) <- nights
                                               , Just v <- [jsonDouble =<< jsonLookup f p] ])
                 | f <- monthlySleepFields ]
    return $ M.fromList (daily ++ vitals)

-- | Every stored day's main sleep period, narrowed to what picking it and
-- 'monthlySleepFields' need. The whole records hold the 5-minute series, so
-- the fields are extracted in SQL rather than decoding each one here.
mainSleepPeriods :: (MonadIO m) => ReaderT SqlBackend m [(DayText, A.Value)]
mainSleepPeriods = do
    let fields = "type" : "time_in_bed" : monthlySleepFields
        extract f = "'" <> f <> "', json_extract(data_json, '$." <> f <> "')"
    rows <- rawSql
        ("SELECT day, json_object(" <> intercalate ", " (map extract fields)
            <> ") FROM sleep_periods WHERE type NOT IN ("
            <> intercalate "," (map (const "?") hiddenSleepTypes)
            <> ") AND " <> countedSleepCondition <> " ORDER BY bedtime_start")
        (map toPersistValue hiddenSleepTypes)
    -- Ordered by bedtime_start and appended with @flip (++)@, so each day's
    -- periods keep the order 'mainSleepPeriod' breaks ties by.
    let byDay = M.fromListWith (flip (++))
            [ (day, [A.Object (parseDataJson p)]) | (Single day, Single p) <- rows ]
    return [ (day, p) | (day, ps) <- M.toList byDay, Just p <- [mainSleepPeriod ps] ]

-- save_advice
saveAdvice
    :: (MonadIO m) => DayText -> DayText -> Text -> ReaderT SqlBackend m ()
saveAdvice periodStart periodEnd content = do
    now <- nowIso
    rawExecute
        "INSERT INTO advice_history (saved_at, period_start, period_end, content) VALUES (?, ?, ?, ?)"
        [ toPersistValue now
        , toPersistValue periodStart
        , toPersistValue periodEnd
        , toPersistValue content
        ]

-- get_advice_dates
getAdviceDates :: (MonadIO m) => ReaderT SqlBackend m [A.Value]
getAdviceDates = do
    rows <- rawSql
        "SELECT substr(saved_at, 1, 10) AS day, MAX(saved_at) AS saved_at, period_start, period_end FROM advice_history GROUP BY substr(saved_at, 1, 10) ORDER BY day"
        []
    return [ A.object
                [ "day"          A..= (day :: Text)
                , "saved_at"     A..= (savedAt :: Text)
                , "period_start" A..= (ps :: Text)
                , "period_end"   A..= (pe :: Text)
                ]
           | (Single day, Single savedAt, Single ps, Single pe) <- rows ]

-- | A saved advice entry, for the prompt and the comparison of a later one.
data SavedAdvice = SavedAdvice
    { savedAdviceAt      :: Text
    , savedAdvicePeriod  :: DateRange
    , savedAdviceContent :: Text
    } deriving (Eq, Show)

-- | The latest advice saved strictly before the given @saved_at@: what a new
-- advice (bounded by 'nowIso') or a saved one follows on from.
getAdviceBefore
    :: (MonadIO m) => Text -> ReaderT SqlBackend m (Maybe SavedAdvice)
getAdviceBefore savedAt = do
    rows <- rawSql
        "SELECT saved_at, period_start, period_end, content FROM advice_history WHERE saved_at < ? ORDER BY saved_at DESC LIMIT 1"
        [toPersistValue savedAt]
    return $ savedAdviceRow <$> headMay rows

savedAdviceRow
    :: (Single Text, Single DayText, Single DayText, Single Text) -> SavedAdvice
savedAdviceRow (Single at, Single ps, Single pe, Single content) =
    SavedAdvice at (DateRange ps pe) content

-- get_advice_for_date: the last advice saved on a (UTC) day.
getAdviceForDate
    :: (MonadIO m) => DayText -> ReaderT SqlBackend m (Maybe SavedAdvice)
getAdviceForDate day = do
    rows <- rawSql
        "SELECT saved_at, period_start, period_end, content FROM advice_history WHERE substr(saved_at, 1, 10) = ? ORDER BY saved_at DESC LIMIT 1"
        [toPersistValue day]
    return $ savedAdviceRow <$> headMay rows

-- | The mean score of each metric over a range, skipping days without one.
-- A metric with no scored day in the range is absent from the map.
getScoreAverages
    :: (MonadIO m)
    => [DailyMetric] -> DateRange -> ReaderT SqlBackend m (Map DailyMetric Double)
getScoreAverages metrics (DateRange start end) = do
    rows <- rawSql
        ("SELECT metric, AVG(score) FROM daily_metrics WHERE metric IN ("
            <> intercalate "," (map (const "?") metrics)
            <> ") AND day >= ? AND day <= ? AND score IS NOT NULL GROUP BY metric")
        (map (toPersistValue . dailyMetricName) metrics
            ++ [toPersistValue start, toPersistValue end])
    return $ M.fromList
        [ (m, avg) | (Single name, Single avg) <- rows, Just m <- [parseDailyMetric name] ]

-- get_sync_status
getSyncStatus :: (MonadIO m) => ReaderT SqlBackend m A.Value
getSyncStatus = do
    entries <- forM syncStatusMetrics $ \metric -> do
        logRow <- rawSql
            "SELECT last_synced_day, last_synced_at FROM sync_log WHERE metric = ?"
            [toPersistValue (metricName metric)]
        cnt <- case metric of
            HeartrateSeries   -> countRaw "SELECT COUNT(*) FROM heartrate" []
            SleepPeriodSeries -> countRaw "SELECT COUNT(*) FROM sleep_periods" []
            EventSeries kind ->
                countRaw "SELECT COUNT(*) FROM oura_events WHERE kind = ?"
                         [toPersistValue (eventKindName kind)]
            Daily daily ->
                countRaw "SELECT COUNT(*) FROM daily_metrics WHERE metric = ?"
                         [toPersistValue (dailyMetricName daily)]
        let (lastDay, lastAt) = maybe (Nothing, Nothing)
                (\(Single ld, Single la) -> (ld, la)) (headMay logRow)
        return (metricName metric, A.object
            [ "last_day"       A..= (lastDay :: Maybe Text)
            , "last_synced_at" A..= (lastAt :: Maybe Text)
            , "rows"           A..= (cnt :: Int)
            ])
    return $ A.toJSON (M.fromList entries)
  where
    countRaw sql params = do
        rs <- rawSql sql params
        return $ maybe 0 unSingle (headMay rs)
