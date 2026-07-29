{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Incremental sync, ported from sync.py.
--
-- "Today" is threaded explicitly (the Python code mocks sync._today_str), and
-- the Oura client is the 'OuraClient' record so tests can inject stubs.
-- Client fetches run in IO and are lifted into the DB action; per-metric
-- OuraError is caught and recorded in the result rather than propagated
-- (matching run_sync's behaviour).
module Sync
    ( defaultStart
    , refetchDays
    , resilienceLevelOrder
    , extractScore
    , findMissingRange
    , syncDailyMetric
    , backfillRanges
    , runSync
    , SyncResult (..)
    ) where

import ClassyPrelude hiding (foldM)
import qualified Data.Aeson       as A
import Data.Aeson                 (Value)
import qualified Data.Aeson.KeyMap   as KM
import qualified Data.Map.Strict  as M
import Control.Monad              (foldM)
import Control.Monad.Logger       (MonadLogger, logError, logInfo)
import Data.Time.Clock            (diffUTCTime)
import Database.Persist.Sql       (SqlBackend, rawSql, Single (..), toPersistValue)

import DateText                   (addDaysT, formatDay, parseDay)
import Db
import Json                       (jsonDouble, jsonInt, jsonLookup, jsonText)
import Oura hiding (getHeartrate)
import qualified Oura

defaultStart :: Text
defaultStart = "2020-01-01"

refetchDays :: Integer
refetchDays = 7

resilienceLevelOrder :: [(Text, Int)]
resilienceLevelOrder =
    [ ("limited", 1), ("adequate", 2), ("solid", 3)
    , ("strong", 4), ("exceptional", 5) ]

-- _extract_score ---------------------------------------------------------

-- | Extract the scalar score for a metric from a raw API record. Returns a
-- JSON Value (Number/Null) mirroring the Python return, and 'Nothing' when the
-- Python code returns None.
extractScore :: Text -> Value -> Maybe Value
extractScore metric record = case metric of
    "sleep"      -> jsonLookup "score" record
    "readiness"  -> jsonLookup "score" record
    "activity"   -> jsonLookup "score" record
    "stress"     -> jsonLookup "stress_high" record
    "spo2"       -> case jsonLookup "spo2_percentage" record of
        Just nested@(A.Object _) -> jsonLookup "average" nested
        other                    -> other
    "resilience" -> do
        level <- jsonText =<< jsonLookup "level" record
        A.Number . fromIntegral <$> lookup level resilienceLevelOrder
    "cardiovascular_age" -> jsonLookup "vascular_age" record
    "temperature"        -> jsonLookup "temperature_deviation" record
    _ -> Nothing

-- | The @day@ field of a raw API record; records without one are skipped.
recordDay :: Value -> Maybe Text
recordDay r = jsonText =<< jsonLookup "day" r

-- find_missing_range -----------------------------------------------------

-- | Return the (start, end) range to fetch, or Nothing if already synced.
findMissingRange
    :: (MonadIO m)
    => Text                        -- ^ today (YYYY-MM-DD)
    -> Text                        -- ^ metric
    -> Text                        -- ^ requested end
    -> ReaderT SqlBackend m (Maybe (Text, Text))
findMissingRange today metric requestedEnd = do
    mlast <- getLastSyncedDay metric
    let end = min requestedEnd today
    case mlast of
        Nothing -> return $ Just (defaultStart, end)
        Just lastDay ->
            let refetchStart = addDaysT (negate (refetchDays - 1)) today
                nextDay      = addDaysT 1 lastDay
                fetchStart   = min refetchStart nextDay
            in return $ if fetchStart > end then Nothing else Just (fetchStart, end)

-- sync_daily_metric ------------------------------------------------------

-- | Fetch and upsert daily metric records. Returns rows written. When syncing
-- readiness, also derives and stores the temperature metric.
syncDailyMetric
    :: (MonadIO m, MonadLogger m)
    => OuraClient -> Text -> Text -> Text
    -> ReaderT SqlBackend m Int
syncDailyMetric client metric start end = do
    records <- liftIO $ fetchFn client metric start end
    let dated = [ (day, r) | r <- records, Just day <- [recordDay r] ]
        count = length dated
    forM_ dated $ \(day, r) ->
        upsertDailyMetric metric day (jsonDouble =<< extractScore metric r) r
    when (metric == "readiness" && not (null records)) $ do
        forM_ dated (uncurry writeTemperature)
        updateSyncLog "temperature" end
    $logInfo ("sync " <> metric <> " " <> start <> ".." <> end
        <> ": " <> tshow count <> " rows")
    return count
  where
    writeTemperature day r =
        upsertDailyMetric "temperature" day
            (jsonDouble =<< jsonLookup "temperature_deviation" r)
            (A.Object $ KM.fromList
                [ ("day", A.String day)
                , ("temperature_deviation", field "temperature_deviation")
                , ("temperature_trend_deviation", field "temperature_trend_deviation")
                , ("body_temperature_score", fromMaybe A.Null
                    (jsonLookup "contributors" r >>= jsonLookup "body_temperature"))
                ])
      where
        field k = fromMaybe A.Null (jsonLookup k r)

-- | Dispatch to the right client method for a daily metric.
fetchFn :: OuraClient -> Text -> (Text -> Text -> IO [Value])
fetchFn client metric = case metric of
    "sleep"              -> getDailySleep client
    "readiness"          -> getDailyReadiness client
    "activity"           -> getDailyActivity client
    "stress"             -> getDailyStress client
    "spo2"               -> getDailySpo2 client
    "resilience"         -> getDailyResilience client
    "cardiovascular_age" -> getDailyCardiovascularAge client
    _                    -> \_ _ -> return []

-- _backfill_ranges -------------------------------------------------------

-- | Contiguous date ranges needed to fill gaps in the backfill window.
-- Heartrate always returns the whole window. Daily metrics treat days with a
-- null score (or missing rows, or today) as gaps.
backfillRanges
    :: (MonadIO m)
    => Text -> Int -> Text
    -> ReaderT SqlBackend m [(Text, Text)]
backfillRanges metric backfillDays today = do
    let windowStart = addDaysT (negate (fromIntegral backfillDays - 1)) today
    if metric == "heartrate"
        then return [(windowStart, today)]
        else do
            rows <- rawSql
                "SELECT day FROM daily_metrics WHERE metric = ? AND day >= ? AND day <= ? AND score IS NOT NULL"
                [toPersistValue metric, toPersistValue windowStart, toPersistValue today]
            let existing = setFromList [ d | Single d <- rows ] :: Set Text
                days = [ formatDay d | d <- [parseDay windowStart .. parseDay today] ]
                isMissing d = not (d `member` existing) || d == today
            return (collectGaps isMissing days)

-- | Group consecutive missing days into (start, end) ranges. @days@ is a
-- contiguous run of dates, so every maximal group of missing days is exactly
-- one range — including a group that runs to the final day (always @today@,
-- which is always missing).
collectGaps :: (Text -> Bool) -> [Text] -> [(Text, Text)]
collectGaps isMissing = mapMaybe gapRange . groupBy ((==) `on` isMissing)
  where
    gapRange grp = case grp of
        (d:_) | isMissing d -> (,) d <$> lastMay grp
        _                   -> Nothing

-- run_sync ---------------------------------------------------------------

data SyncResult = SyncResult
    { syncedCounts :: M.Map Text Int
    , syncErrors   :: M.Map Text Text
    } deriving (Show, Eq)

allDailyMetrics :: [Text]
allDailyMetrics =
    ["sleep", "readiness", "activity", "stress", "spo2", "resilience", "cardiovascular_age"]

-- | Rows written by one fetch range, plus the failure that stopped it.
type RangeResult = (Int, Maybe Text)

-- | Run an action over each range in turn, summing the rows written and
-- stopping at the first failure (the Python loop breaks likewise). Rows
-- written before the failure are still reported.
foldRanges
    :: (Monad m) => ((Text, Text) -> m RangeResult) -> [(Text, Text)] -> m RangeResult
foldRanges run = go 0
  where
    go total [] = return (total, Nothing)
    go total (range:rest) = do
        (rows, merr) <- run range
        case merr of
            Just err -> return (total + rows, Just err)
            Nothing  -> go (total + rows) rest

-- | A caught 'OuraError' contributes no rows, mirroring the Python handler.
rangeResult :: Either Text Int -> RangeResult
rangeResult (Left err)   = (0, Just err)
rangeResult (Right rows) = (rows, Nothing)

-- | Run incremental sync for all (or specified) metrics.
runSync
    :: (MonadUnliftIO m, MonadLogger m)
    => Text                   -- ^ today
    -> OuraClient
    -> Maybe Text             -- ^ requested_start
    -> Maybe Text             -- ^ requested_end
    -> Maybe [Text]           -- ^ metrics (Nothing = all + heartrate)
    -> Int                    -- ^ backfill_days
    -> ReaderT SqlBackend m SyncResult
runSync today client requestedStart requestedEnd mmetrics backfillDays = do
    let end = fromMaybe today requestedEnd
        targets = fromMaybe (allDailyMetrics ++ ["heartrate"]) mmetrics
    $logInfo ("sync start: through " <> end
        <> ", backfill_days=" <> tshow backfillDays
        <> ", metrics=" <> intercalate "," targets)
    started <- liftIO getCurrentTime
    result <- foldM (step end) (SyncResult M.empty M.empty) targets
    finished <- liftIO getCurrentTime
    let total = sum (M.elems (syncedCounts result))
        errs = M.size (syncErrors result)
    $logInfo ("sync done: " <> tshow total <> " rows, "
        <> tshow errs <> " errors, "
        <> tshow (diffUTCTime finished started))
    return result
  where
    step end acc metric
        | metric == "temperature" = return acc  -- derived from readiness
        | otherwise = do
            ranges <- rangesFor end metric
            (rows, merr) <- foldRanges (syncRange metric) ranges
            return SyncResult
                { syncedCounts = M.insert metric rows (syncedCounts acc)
                , syncErrors   = maybe id (M.insert metric) merr (syncErrors acc)
                }

    -- The incremental range (or the caller's explicit start) plus the backfill
    -- gaps, dropping an incremental range a backfill range already covers.
    rangesFor end metric = do
        incremental <- case requestedStart of
            Just start -> return (Just (start, end))
            Nothing    -> findMissingRange today metric end
        backfill <- if backfillDays > 0 && isNothing requestedStart
                    then backfillRanges metric backfillDays today
                    else return []
        let covered (s, e) = any (\(bs, be) -> bs <= s && be >= e) backfill
        return (filter (not . covered) (maybe [] pure incremental) ++ backfill)

    syncRange metric
        | metric == "heartrate" = syncHeartrateRange
        | otherwise             = syncDailyRange metric

    syncDailyRange metric (fetchStart, fetchEnd) =
        rangeResult <$> tryOura metric (do
            rows <- syncDailyMetric client metric fetchStart fetchEnd
            updateSyncLog metric fetchEnd
            return rows)

    -- Heartrate: each fetch range is walked backwards in <=30-day windows.
    syncHeartrateRange (fetchStart, fetchEnd) = go 0 fetchEnd
      where
        go total windowEnd = do
            let windowStart = max fetchStart (addDaysT (-29) windowEnd)
            r <- tryOura "heartrate" $ do
                recs <- liftIO $ Oura.getHeartrate client windowStart windowEnd
                rows <- upsertHeartrateBatch (map toHrPair recs)
                updateSyncLog "heartrate" fetchEnd
                return rows
            case r of
                Left msg -> return (total, Just msg)
                Right rows
                    | windowStart <= fetchStart -> return (total + rows, Nothing)
                    | otherwise -> go (total + rows) (addDaysT (-1) windowStart)

    toHrPair v =
        ( fromMaybe "" (jsonText =<< jsonLookup "timestamp" v)
        , jsonInt =<< jsonLookup "bpm" v
        )

-- | Run a DB+client action, catching OuraError and returning its message.
-- The failure is logged here: callers only fold it into 'syncErrors', so
-- without this an errored metric leaves no trace in the log.
tryOura
    :: (MonadUnliftIO m, MonadLogger m)
    => Text                   -- ^ metric, for the log line
    -> ReaderT SqlBackend m a
    -> ReaderT SqlBackend m (Either Text a)
tryOura metric action = do
    r <- try action
    case r of
        Left (OuraError _ msg) -> do
            $logError $ "sync failed for " <> metric <> ": " <> msg
            return (Left msg)
        Right a                -> return (Right a)
