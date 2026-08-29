{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies      #-}

-- | JSON API handlers ported from app.py (auth, metrics, heartrate, sync).
-- Advice handlers live in Handler.Advice (Phase 5).
module Handler.Api where

import Import
import qualified Data.Aeson as A
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Network.HTTP.Types (status202, status400, status500)

import DateText (DateRange (..), DayText, addDaysT, parseDayText, todayUtc)
import Json (jsonArray, jsonText, jsonLookup)
import Metric (Metric (..), dailyMetricName, dashboardMetrics,
               metricName, parseDailyMetric)
import qualified Db
import qualified Sync
import Oura (realClient)

-- | Parse start/end query params, defaulting end=today, start=30 days ago.
parseRange :: Handler DateRange
parseRange = do
    today <- todayUtc
    end   <- paramOr "end" today
    start <- paramOr "start" (addDaysT (-30) today)
    return (DateRange start end)
  where
    paramOr name fallback =
        maybe (return fallback) (requireDayText name) =<< lookupGetParam name

-- | A @YYYY-MM-DD@ value supplied by the client, or a 400.
--
-- Wrapping the raw text in 'DayText' unchecked is not enough: such a day goes
-- on to calendar arithmetic (the heartrate windows in @Sync@ walk backwards
-- with 'addDaysT'), where @DateText.parseDay@ answers an impossible date like
-- @1999-13-45@ with @error@ — a 500 for what is really a bad request.
requireDayText :: Text -> Text -> Handler DayText
requireDayText name raw =
    maybe (sendStatusJSON status400
              (A.object ["error" A..= ("Invalid " <> name <> " date: " <> raw)]))
          return
          (parseDayText raw)

-- Auth -------------------------------------------------------------------

postLoginR :: Handler Value
postLoginR = do
    stored <- appPassword . appSettings <$> getYesod
    when (null stored) $
        sendStatusJSON status500 (A.object ["error" A..= ("APP_PASSWORD not configured" :: Text)])
    body <- jsonBodyOrEmpty
    ok <- checkPassword (fromMaybe "" (jsonText =<< jsonLookup "password" body))
    if ok
        then do
            setSession sessionAuthKey "1"
            returnJson (A.object ["ok" A..= True])
        else sendStatusJSON status401 (A.object ["error" A..= ("Invalid password" :: Text)])

postLogoutR :: Handler Value
postLogoutR = do
    deleteSession sessionAuthKey
    returnJson (A.object ["ok" A..= True])

-- Metrics ----------------------------------------------------------------

getMetricsR :: Handler Value
getMetricsR = do
    requireAuth
    range <- parseRange
    requested <- lookupGetParam "metric"
    let names = maybe [] (filter (not . null) . map T.strip . T.splitOn ",") requested
        metrics = case requested of
            Nothing -> dashboardMetrics
            Just _  -> [ m | Just m <- map parseDailyMetric names
                           , m `elem` dashboardMetrics ]
    byMetric <- runDB $ M.fromList <$>
        forM metrics (\m ->
            (,) (dailyMetricName m) <$> Db.getDailyMetrics m range)
    returnJson byMetric

getMetricR :: Text -> Handler Value
getMetricR name = do
    requireAuth
    metric <- case parseDailyMetric name of
        Just m | m `elem` dashboardMetrics -> return m
        _ -> sendStatusJSON status400
                (A.object ["error" A..= ("Unknown metric: " <> name)])
    range <- parseRange
    rows <- runDB $ Db.getDailyMetrics metric range
    returnJson rows

-- Heartrate --------------------------------------------------------------

getHeartrateR :: Handler Value
getHeartrateR = do
    requireAuth
    range <- parseRange
    rows <- runDB $ Db.getHeartrate range
    returnJson rows

-- Sleep periods ----------------------------------------------------------

-- | Sleep period documents in the range, narrowed to the fields the sleep
-- stage charts read. Several records can share a @day@, so unlike the daily
-- metrics this is a flat array rather than a map.
getSleepPeriodsR :: Handler Value
getSleepPeriodsR = do
    requireAuth
    range <- parseRange
    rows <- runDB $ Db.getSleepPeriods range
    returnJson rows

-- Sync -------------------------------------------------------------------

getSyncStatusR :: Handler Value
getSyncStatusR = do
    requireAuth
    status <- runDB Db.getSyncStatus
    returnJson status

postSyncR :: Handler Value
postSyncR = do
    requireAuth
    body <- jsonBodyOrEmpty
    let field k = jsonText =<< jsonLookup k body
        requestedMetrics = mapMaybe parseMetricName
                               <$> (jsonArray =<< jsonLookup "metrics" body)
    requestedStart <- traverse (requireDayText "start") (field "start")
    mrequestedEnd  <- traverse (requireDayText "end") (field "end")
    today <- todayUtc
    let requestedEnd = fromMaybe today mrequestedEnd

    app <- getYesod
    client <- case appOuraClientOverride app of
        Just c  -> return c
        Nothing -> do
            let token = appOuraToken (appSettings app)
            when (null token) $
                sendStatusJSON status500 (A.object ["error" A..= ("OURA_TOKEN not set" :: Text)])
            return (realClient (appPlainLogger app) token)
    result <- runDB $ Sync.runSync today client requestedStart (Just requestedEnd) requestedMetrics 0
    sendStatusJSON status202 (syncResultToJson result)

-- | Convert SyncResult to the app.py {"synced": {...}, "errors": {...}} shape.
syncResultToJson :: Sync.SyncResult -> Value
syncResultToJson r = A.object
    [ "synced" A..= M.mapKeys metricName (Sync.syncedCounts r)
    , "errors" A..= M.mapKeys metricName (Sync.syncErrors r)
    ]

-- | A metric name from the request body. The two series are sync targets but
-- not daily metrics, so they are matched by name before falling back.
parseMetricName :: Value -> Maybe Metric
parseMetricName v = do
    name <- jsonText v
    let series = [ (metricName m, m) | m <- [HeartrateSeries, SleepPeriodSeries] ]
    lookup name series <|> (Daily <$> parseDailyMetric name)

-- | The request body decoded as JSON, or an empty object when it is missing,
-- not JSON, or malformed (Python's @request.get_json(silent=True) or {}@).
--
-- 'parseCheckJsonBody' reports those failures in its result, so "silent" stays
-- scoped to a parse failure. The @catch \@SomeException@ this replaces also
-- swallowed unrelated exceptions, including async ones.
jsonBodyOrEmpty :: Handler Value
jsonBodyOrEmpty = do
    result <- parseCheckJsonBody
    return $ case result of
        A.Success v -> v
        A.Error _   -> A.object []
