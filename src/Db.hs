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
import Database.Persist.Sql       (rawExecute, rawSql, Single (..))

import DateText
import Json                       (jsonLookup, jsonText)
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
-- reads, so reads project it down: 180 days is ~160KB this way against ~900KB
-- raw. The whole record stays in @data_json@, so widening this list later
-- needs no re-sync.
sleepPeriodFields :: [Text]
sleepPeriodFields =
    [ "id", "day", "type", "period"
    , "bedtime_start", "bedtime_end"
    , "sleep_phase_5_min"
    , "deep_sleep_duration", "light_sleep_duration", "rem_sleep_duration"
    , "awake_time", "total_sleep_duration", "time_in_bed"
    , "efficiency", "latency"
    ]

-- | Period types the charts ignore: @deleted@ is the tombstone for a sleep the
-- user removed, and @rest@ is a detection the user rejected as "not asleep"
-- (Oura leaves it out of the daily scores too).
hiddenSleepTypes :: [Text]
hiddenSleepTypes = ["deleted", "rest"]

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
            <> ") ORDER BY bedtime_start")
        ([toPersistValue start, toPersistValue end]
            ++ map toPersistValue hiddenSleepTypes)
    return [ projectSleepPeriod (parseDataJson dj) | Single dj <- rows ]

-- | Narrow a stored record to 'sleepPeriodFields'.
projectSleepPeriod :: A.Object -> A.Value
projectSleepPeriod =
    A.Object . KM.filterWithKey (\k _ -> K.toText k `elem` sleepPeriodFields)

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

-- get_advice_for_date
getAdviceForDate
    :: (MonadIO m) => DayText -> ReaderT SqlBackend m (Maybe A.Value)
getAdviceForDate day = do
    rows <- rawSql
        "SELECT saved_at, period_start, period_end, content FROM advice_history WHERE substr(saved_at, 1, 10) = ? ORDER BY saved_at DESC LIMIT 1"
        [toPersistValue day]
    return $ entryJson <$> headMay rows
  where
    entryJson
        :: (Single Text, Single Text, Single Text, Single Text) -> A.Value
    entryJson (Single savedAt, Single ps, Single pe, Single content) = A.object
        [ "saved_at"     A..= savedAt
        , "period_start" A..= ps
        , "period_end"   A..= pe
        , "content"      A..= content
        ]

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
