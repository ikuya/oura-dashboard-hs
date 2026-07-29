{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | JSON API handlers ported from app.py (auth, metrics, heartrate, sync).
-- Advice handlers live in Handler.Advice (Phase 5).
module Handler.Api where

import Import
import qualified Data.Aeson as A
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Network.HTTP.Types (status202, status400, status500)

import DateText (addDaysT, todayUtc)
import Json (jsonArray, jsonText, jsonLookup)
import qualified Db
import qualified Sync
import Oura (realClient)

-- | The daily metrics served by /api/metrics (app.py DAILY_METRICS).
dailyMetrics :: [Text]
dailyMetrics =
    [ "sleep", "readiness", "activity", "stress", "spo2"
    , "resilience", "cardiovascular_age", "temperature" ]

-- | Parse start/end query params, defaulting end=today, start=30 days ago.
parseRange :: Handler (Text, Text)
parseRange = do
    today <- todayUtc
    end   <- paramOr "end" today
    start <- paramOr "start" (addDaysT (-30) today)
    return (start, end)
  where
    paramOr name fallback = fromMaybe fallback <$> lookupGetParam name

-- Auth -------------------------------------------------------------------

postLoginR :: Handler Value
postLoginR = do
    stored <- appPassword . appSettings <$> getYesod
    when (null stored) $
        sendStatusJSON status500 (A.object ["error" A..= ("APP_PASSWORD not configured" :: Text)])
    body <- (requireCheckJsonBody :: Handler Value) `parseBodyOr` A.object []
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
    (start, end) <- parseRange
    requested <- fromMaybe (intercalate "," dailyMetrics) <$> lookupGetParam "metric"
    let metrics = [ m | m <- map T.strip (T.splitOn "," requested), not (null m) ]
    byMetric <- runDB $ M.fromList <$>
        forM (filter (`elem` dailyMetrics) metrics) (\m ->
            (,) m <$> Db.getDailyMetrics m start end)
    returnJson byMetric

getMetricR :: Text -> Handler Value
getMetricR metric = do
    requireAuth
    when (metric `notElem` dailyMetrics) $
        sendStatusJSON status400 (A.object ["error" A..= ("Unknown metric: " <> metric)])
    (start, end) <- parseRange
    rows <- runDB $ Db.getDailyMetrics metric start end
    returnJson rows

-- Heartrate --------------------------------------------------------------

getHeartrateR :: Handler Value
getHeartrateR = do
    requireAuth
    (start, end) <- parseRange
    rows <- runDB $ Db.getHeartrate start end
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
    body <- (requireCheckJsonBody :: Handler Value) `parseBodyOr` A.object []
    let field k = jsonText =<< jsonLookup k body
        requestedStart = field "start"
        requestedMetrics = mapMaybe jsonText <$> (jsonArray =<< jsonLookup "metrics" body)
    today <- todayUtc
    let requestedEnd = fromMaybe today (field "end")

    app <- getYesod
    client <- case appOuraClientOverride app of
        Just c  -> return c
        Nothing -> do
            let token = appOuraToken (appSettings app)
            when (null token) $
                sendStatusJSON status500 (A.object ["error" A..= ("OURA_TOKEN not set" :: Text)])
            return (realClient token)
    result <- runDB $ Sync.runSync today client requestedStart (Just requestedEnd) requestedMetrics 0
    sendStatusJSON status202 (syncResultToJson result)

-- | Convert SyncResult to the app.py {"synced": {...}, "errors": {...}} shape.
syncResultToJson :: Sync.SyncResult -> Value
syncResultToJson r = A.object
    [ "synced" A..= Sync.syncedCounts r
    , "errors" A..= Sync.syncErrors r
    ]

-- | Run a handler that may fail JSON parsing, falling back to a default
-- (mirrors Python's @request.get_json(silent=True) or {}@).
parseBodyOr :: Handler a -> a -> Handler a
parseBodyOr action def = action `catch` (\(_ :: SomeException) -> return def)
