{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Oura Ring API v2 client, ported from oura_client.py.
--
-- The client is a record of fetch functions so tests can substitute stubs
-- (mirroring the MagicMock used in test_sync.py). 'realClient' provides the
-- http-conduit implementation with next_token pagination, a 15s timeout, and
-- the same error handling as the Python client.
module Oura
    ( OuraClient (..)
    , OuraError (..)
    , realClient
    , dateToDatetime
    ) where

import ClassyPrelude
import Data.Aeson                 (Value)
import Control.Monad.Logger        (LogLevel (..))
import Network.HTTP.Simple
import Network.HTTP.Client         (responseTimeoutMicro)

import DateText                    (DateRange (..), DayText (..))
import Json                        (jsonArray, jsonText, jsonLookup)
import Logging                     (AppLog (..))

-- | Error raised by the Oura client. Mirrors oura_client.OuraAPIError:
-- carries an optional HTTP status code and a message.
data OuraError = OuraError
    { ouraErrorStatus  :: Maybe Int
    , ouraErrorMessage :: Text
    } deriving (Show)

instance Exception OuraError

-- | The set of fetch operations the sync layer needs. Each takes an inclusive
-- date range and returns the concatenated @data@ array.
data OuraClient = OuraClient
    { getDailySleep             :: DateRange -> IO [Value]
    , getDailyReadiness         :: DateRange -> IO [Value]
    , getDailyActivity          :: DateRange -> IO [Value]
    , getDailyStress            :: DateRange -> IO [Value]
    , getDailySpo2              :: DateRange -> IO [Value]
    , getDailyResilience        :: DateRange -> IO [Value]
    , getDailyCardiovascularAge :: DateRange -> IO [Value]
    , getVO2Max                 :: DateRange -> IO [Value]
    , getHeartrate              :: DateRange -> IO [Value]
    , getSleepPeriods           :: DateRange -> IO [Value]
      -- ^ Sleep period documents. Dated like the daily endpoints, but several
      -- records can share a @day@ (a long sleep plus naps).
    }

baseUrl :: Text
baseUrl = "https://api.ouraring.com"

apiTimeoutMicros :: Int
apiTimeoutMicros = 15 * 1000000

-- | Build the real client bound to a bearer token. Fetches run in plain IO,
-- so the log destination is passed in rather than looked up.
realClient :: AppLog -> Text -> OuraClient
realClient appLog token = OuraClient
    { getDailySleep             = getDated "/v2/usercollection/daily_sleep"
    , getDailyReadiness         = getDated "/v2/usercollection/daily_readiness"
    , getDailyActivity          = getDated "/v2/usercollection/daily_activity"
    , getDailyStress            = getDated "/v2/usercollection/daily_stress"
    , getDailySpo2              = getDated "/v2/usercollection/daily_spo2"
    , getDailyResilience        = getDated "/v2/usercollection/daily_resilience"
    , getDailyCardiovascularAge = getDated "/v2/usercollection/daily_cardiovascular_age"
    , getVO2Max                 = getDated "/v2/usercollection/vO2_max"
    , getSleepPeriods           = getDated "/v2/usercollection/sleep"
    , getHeartrate              = \range -> getPaged
        "/v2/usercollection/heartrate"
        [ ("start_datetime", dateToDatetime (rangeStart range) False)
        , ("end_datetime",   dateToDatetime (rangeEnd range) True) ]
    }
  where
    getDated path range = getPaged path
        [ ("start_date", unDayText (rangeStart range))
        , ("end_date",   unDayText (rangeEnd range)) ]

    -- Follow next_token pagination, concatenating each page's data array.
    getPaged :: Text -> [(Text, Text)] -> IO [Value]
    getPaged path params = go Nothing []
      where
        go mnext acc = do
            let queryParams = params ++ maybe [] (\t -> [("next_token", t)]) mnext
            body <- httpGet path queryParams
            let page = fromMaybe [] (jsonArray =<< jsonLookup "data" body)
                acc' = acc ++ page
            writeLog appLog LevelDebug
                ("GET " <> path <> ": " <> tshow (length page)
                 <> " records, " <> tshow (length acc') <> " total")
            maybe (return acc') (\t -> go (Just t) acc')
                  (jsonText =<< jsonLookup "next_token" body)

    httpGet :: Text -> [(Text, Text)] -> IO Value
    httpGet path params = do
        let url = baseUrl <> path
        req0 <- parseRequest (unpack ("GET " <> url))
        let req = setRequestHeader "Authorization" ["Bearer " <> encodeUtf8 token]
                $ setRequestQueryString
                    [ (encodeUtf8 k, Just (encodeUtf8 v)) | (k, v) <- params ]
                $ setRequestResponseTimeout
                    (responseTimeoutMicro apiTimeoutMicros)
                $ req0
        -- httpJSON returns non-2xx responses normally; only transport/JSON
        -- failures throw. Check status ourselves and raise OuraError to match
        -- the Python client's raise_for_status + RequestException handling.
        eresp <- try (httpJSON req)
        case eresp of
            Left (e :: HttpException) -> do
                writeLog appLog LevelWarn ("GET " <> path <> " failed: " <> tshow e)
                throwIO $ OuraError Nothing ("Request failed: " <> tshow e)
            Right resp -> do
                let status = getResponseStatusCode resp
                if status >= 200 && status < 300
                    then return (getResponseBody resp)
                    else do
                        writeLog appLog LevelWarn
                            ("GET " <> path <> " returned HTTP " <> tshow status)
                        throwIO (mkHttpError status)

    mkHttpError :: Int -> OuraError
    mkHttpError status =
        let base = "HTTP " <> tshow status
            msg = if status == 401
                  then base <> "\nHint: Check your OURA_TOKEN."
                  else base
        in OuraError (Just status) msg

-- | @date_to_datetime_str@ from the Python client.
dateToDatetime :: DayText -> Bool -> Text
dateToDatetime (DayText dateStr) endOfDay =
    dateStr <> "T" <> (if endOfDay then "23:59:59" else "00:00:00")
