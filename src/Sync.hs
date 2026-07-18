{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

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
import qualified Data.Aeson.Key      as K
import qualified Data.Aeson.KeyMap   as KM
import qualified Data.Map.Strict  as M
import Control.Monad              (foldM)
import Data.Time.Calendar         (Day, addDays)
import Database.Persist.Sql       (SqlBackend, rawSql, Single (..), toPersistValue)

import Db
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

-- Date helpers (YYYY-MM-DD <-> Day) --------------------------------------

parseDay :: Text -> Day
parseDay t = case parseTimeM True defaultTimeLocale "%Y-%m-%d" (unpack t) of
    Just d  -> d
    Nothing -> error ("invalid date: " <> unpack t)

showDay :: Day -> Text
showDay = pack . formatTime defaultTimeLocale "%Y-%m-%d"

addDaysT :: Integer -> Text -> Text
addDaysT n = showDay . addDays n . parseDay

-- | Look up a key in a JSON object, if the Value is an object.
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup k (A.Object o) = KM.lookup (K.fromText k) o
jsonLookup _ _            = Nothing

asNumber :: Value -> Maybe Value
asNumber v@(A.Number _) = Just v
asNumber _              = Nothing

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
        Just (A.Object o) -> KM.lookup "average" o
        other             -> other
    "resilience" -> do
        lvl <- jsonLookup "level" record
        case lvl of
            A.String s -> A.Number . fromIntegral <$> lookup s resilienceLevelOrder
            _          -> Nothing
    "cardiovascular_age" -> jsonLookup "vascular_age" record
    "temperature"        -> jsonLookup "temperature_deviation" record
    _ -> Nothing

-- | The score as a Maybe Double for the DB column.
scoreToDouble :: Maybe Value -> Maybe Double
scoreToDouble (Just (A.Number n)) = Just (realToFrac n)
scoreToDouble _                   = Nothing

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
    :: (MonadIO m)
    => OuraClient -> Text -> Text -> Text
    -> ReaderT SqlBackend m Int
syncDailyMetric client metric start end = do
    records <- liftIO $ fetchFn client metric start end
    count <- foldM writeRecord 0 records
    when (metric == "readiness" && not (null records)) $
        forM_ records writeTemperature >> updateSyncLog "temperature" end
    return count
  where
    writeRecord acc r = case jsonLookup "day" r of
        Just (A.String day) -> do
            let score = scoreToDouble (extractScore metric r)
            upsertDailyMetric metric day score r
            return (acc + 1)
        _ -> return acc

    writeTemperature r = case jsonLookup "day" r of
        Just (A.String day) -> do
            let tempRecord = A.Object $ KM.fromList
                    [ ("day", A.String day)
                    , ("temperature_deviation",
                        fromMaybe A.Null (jsonLookup "temperature_deviation" r))
                    , ("temperature_trend_deviation",
                        fromMaybe A.Null (jsonLookup "temperature_trend_deviation" r))
                    , ("body_temperature_score",
                        fromMaybe A.Null (jsonLookup "contributors" r
                                          >>= jsonLookup "body_temperature"))
                    ]
                score = scoreToDouble (asNumber =<< jsonLookup "temperature_deviation" r)
            upsertDailyMetric "temperature" day score tempRecord
        _ -> return ()

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
                days = [ showDay d | d <- [parseDay windowStart .. parseDay today] ]
                isMissing d = not (d `member` existing) || d == today
            return (collectGaps isMissing days)

-- | Group consecutive missing days into (start, end) ranges. A gap still open
-- at the final day closes at that day (which is always @today@, always missing).
collectGaps :: (Text -> Bool) -> [Text] -> [(Text, Text)]
collectGaps isMissing days = go Nothing days
  where
    lastDay = case reverse days of (d:_) -> Just d; [] -> Nothing
    go mstart [] = case (mstart, lastDay) of
        (Just s, Just l) -> [(s, l)]
        _                -> []
    go mstart (d:ds)
        | isMissing d = case mstart of
            Nothing -> go (Just d) ds
            Just _  -> go mstart ds
        | otherwise = case mstart of
            Nothing -> go Nothing ds
            Just s  -> (s, prevDay d) : go Nothing ds
    prevDay = addDaysT (-1)

-- run_sync ---------------------------------------------------------------

data SyncResult = SyncResult
    { syncedCounts :: M.Map Text Int
    , syncErrors   :: M.Map Text Text
    } deriving (Show, Eq)

allDailyMetrics :: [Text]
allDailyMetrics =
    ["sleep", "readiness", "activity", "stress", "spo2", "resilience", "cardiovascular_age"]

-- | Run incremental sync for all (or specified) metrics.
runSync
    :: (MonadUnliftIO m)
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
    foldM (step end) (SyncResult M.empty M.empty) targets
  where
    step end acc metric
        | metric == "temperature" = return acc  -- derived from readiness
        | otherwise = do
            rng0 <- findMissingRange today metric end
            let rng = case requestedStart of
                    Just s  -> Just (s, end)
                    Nothing -> rng0
            backfill <- if backfillDays > 0 && isNothing requestedStart
                        then backfillRanges metric backfillDays today
                        else return []
            let covered r = any (\(bs, be) -> bs <= fst r && be >= snd r) backfill
                incremental = case rng of
                    Just r | not (covered r) -> [r]
                    _                        -> []
                ranges = incremental ++ backfill
            if null ranges
                then return acc { syncedCounts = M.insert metric 0 (syncedCounts acc) }
                else if metric == "heartrate"
                    then syncHeartrateRanges acc end ranges
                    else syncDailyRanges acc metric ranges

    -- Daily metric: fetch each range, catch OuraError per range.
    syncDailyRanges acc metric ranges = do
        (total, merr) <- foldM (\(t, e) (fs, fe) ->
            case e of
                Just _ -> return (t, e)  -- stop after first error (Python breaks)
                Nothing -> do
                    r <- tryOura $ do
                        c <- syncDailyMetric client metric fs fe
                        updateSyncLog metric fe
                        return c
                    case r of
                        Left msg -> return (t, Just msg)
                        Right c  -> return (t + c, Nothing)
            ) (0, Nothing) ranges
        return acc
            { syncedCounts = M.insert metric total (syncedCounts acc)
            , syncErrors   = maybe (syncErrors acc)
                                   (\m -> M.insert metric m (syncErrors acc)) merr
            }

    -- Heartrate: each fetch range is walked backwards in <=30-day windows.
    syncHeartrateRanges acc end ranges = do
        (total, merr) <- foldM (\(t, e) (fs, fe) ->
            case e of
                Just _  -> return (t, e)
                Nothing -> hrRange t fs fe end
            ) (0, Nothing) ranges
        return acc
            { syncedCounts = M.insert "heartrate" total (syncedCounts acc)
            , syncErrors   = maybe (syncErrors acc)
                                   (\m -> M.insert "heartrate" m (syncErrors acc)) merr
            }

    hrRange total fetchStart fetchEnd _fullEnd = loop total fetchEnd
      where
        loop t windowEnd = do
            let windowStart = max fetchStart (addDaysT (-29) windowEnd)
            r <- tryOura $ do
                recs <- liftIO $ Oura.getHeartrate client windowStart windowEnd
                c <- upsertHeartrateBatch (map toHrPair recs)
                updateSyncLog "heartrate" fetchEnd
                return c
            case r of
                Left msg -> return (t, Just msg)
                Right c ->
                    if windowStart <= fetchStart
                        then return (t + c, Nothing)
                        else loop (t + c) (addDaysT (-1) windowStart)

    toHrPair v =
        ( case jsonLookup "timestamp" v of Just (A.String s) -> s; _ -> ""
        , case jsonLookup "bpm" v of
            Just (A.Number n) -> Just (round n)
            _                 -> Nothing
        )

-- | Run a DB+client action, catching OuraError and returning its message.
tryOura
    :: (MonadUnliftIO m)
    => ReaderT SqlBackend m a
    -> ReaderT SqlBackend m (Either Text a)
tryOura action = do
    r <- try action
    return $ case r of
        Left (OuraError _ msg) -> Left msg
        Right a                -> Right a
