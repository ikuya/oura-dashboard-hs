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
mergeRow :: Text -> Maybe Double -> A.Object -> A.Value
mergeRow day mscore o =
    A.Object $ KM.insert "score" (maybe A.Null A.toJSON mscore)
             $ KM.insert "day" (A.toJSON day) o

-- upsert_daily_metric
upsertDailyMetric
    :: (MonadIO m)
    => Text -> Text -> Maybe Double -> A.Value -> ReaderT SqlBackend m ()
upsertDailyMetric metric day score dataObj = do
    now <- nowIso
    let dataText = decodeUtf8 (toStrict (A.encode dataObj))
    rawExecute
        "INSERT OR REPLACE INTO daily_metrics (metric, day, score, data_json, synced_at) VALUES (?, ?, ?, ?, ?)"
        [ toPersistValue metric
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
updateSyncLog :: (MonadIO m) => Text -> Text -> ReaderT SqlBackend m ()
updateSyncLog metric lastDay = do
    now <- nowIso
    rawExecute
        "INSERT OR REPLACE INTO sync_log (metric, last_synced_day, last_synced_at) VALUES (?, ?, ?)"
        [toPersistValue metric, toPersistValue lastDay, toPersistValue now]

-- get_last_synced_day
getLastSyncedDay :: (MonadIO m) => Text -> ReaderT SqlBackend m (Maybe Text)
getLastSyncedDay metric = do
    rows <- rawSql
        "SELECT last_synced_day FROM sync_log WHERE metric = ?"
        [toPersistValue metric]
    return $ case rows of
        (Single d : _) -> Just d
        _              -> Nothing

-- get_daily_metrics
getDailyMetrics
    :: (MonadIO m) => Text -> Text -> Text -> ReaderT SqlBackend m [A.Value]
getDailyMetrics metric start end = do
    rows <- rawSql
        "SELECT day, score, data_json FROM daily_metrics WHERE metric = ? AND day >= ? AND day <= ? ORDER BY day"
        [toPersistValue metric, toPersistValue start, toPersistValue end]
    return [ mergeRow day score (parseDataJson dj)
           | (Single day, Single score, Single dj) <- rows ]

-- get_daily_metrics_bulk
getDailyMetricsBulk
    :: (MonadIO m)
    => [Text] -> Text -> Text -> ReaderT SqlBackend m (Map Text [A.Value])
getDailyMetricsBulk metrics start end
    | null metrics = return mempty
    | otherwise = do
        let placeholders = intercalate "," (map (const "?") metrics)
            sql = "SELECT metric, day, score, data_json FROM daily_metrics WHERE metric IN ("
                  <> placeholders
                  <> ") AND day >= ? AND day <= ? ORDER BY metric, day"
        rows <- rawSql sql
            (map toPersistValue metrics ++ [toPersistValue start, toPersistValue end])
        let empty = M.fromList [(mk, []) | mk <- metrics] :: M.Map Text [A.Value]
            add acc (Single mt, Single day, Single score, Single dj) =
                M.insertWith (\new old -> old ++ new) mt [mergeRow day score (parseDataJson dj)] acc
        return $ foldl' add empty rows

-- get_heartrate
getHeartrate
    :: (MonadIO m) => Text -> Text -> ReaderT SqlBackend m [A.Value]
getHeartrate start end = do
    rows <- rawSql
        "SELECT timestamp, bpm FROM heartrate WHERE day >= ? AND day <= ? ORDER BY timestamp"
        [toPersistValue start, toPersistValue end]
    return [ A.object ["timestamp" A..= (ts :: Text), "bpm" A..= (bpm :: Int)]
           | (Single ts, Single bpm) <- rows ]

-- save_advice
saveAdvice
    :: (MonadIO m) => Text -> Text -> Text -> ReaderT SqlBackend m ()
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
    :: (MonadIO m) => Text -> ReaderT SqlBackend m (Maybe A.Value)
getAdviceForDate day = do
    rows <- rawSql
        "SELECT saved_at, period_start, period_end, content FROM advice_history WHERE substr(saved_at, 1, 10) = ? ORDER BY saved_at DESC LIMIT 1"
        [toPersistValue day]
    return $ case rows of
        ((Single savedAt, Single ps, Single pe, Single content) : _) ->
            Just $ A.object
                [ "saved_at"     A..= (savedAt :: Text)
                , "period_start" A..= (ps :: Text)
                , "period_end"   A..= (pe :: Text)
                , "content"      A..= (content :: Text)
                ]
        _ -> Nothing

-- | Metrics reported by get_sync_status, in the Python order.
syncStatusMetrics :: [Text]
syncStatusMetrics =
    [ "sleep", "readiness", "activity", "stress", "spo2"
    , "resilience", "cardiovascular_age", "vo2_max", "temperature", "heartrate"
    ]

-- get_sync_status
getSyncStatus :: (MonadIO m) => ReaderT SqlBackend m A.Value
getSyncStatus = do
    entries <- forM syncStatusMetrics $ \metric -> do
        logRow <- rawSql
            "SELECT last_synced_day, last_synced_at FROM sync_log WHERE metric = ?"
            [toPersistValue metric]
        cnt <- if metric == "heartrate"
            then countRaw "SELECT COUNT(*) FROM heartrate" []
            else countRaw "SELECT COUNT(*) FROM daily_metrics WHERE metric = ?"
                          [toPersistValue metric]
        let (lastDay, lastAt) = case logRow of
                ((Single ld, Single la) : _) -> (ld, la)
                _ -> (Nothing, Nothing)
        return (metric, A.object
            [ "last_day"       A..= (lastDay :: Maybe Text)
            , "last_synced_at" A..= (lastAt :: Maybe Text)
            , "rows"           A..= (cnt :: Int)
            ])
    return $ A.Object $ KM.fromList [ (K.fromText m, v) | (m, v) <- entries ]
  where
    countRaw sql params = do
        rs <- rawSql sql params
        return $ case rs of
            (Single n : _) -> n
            _              -> 0
