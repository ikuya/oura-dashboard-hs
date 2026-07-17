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
import qualified Data.Aeson       as A
import Data.Aeson                 (Value)
import qualified Data.Vector      as V
import Network.HTTP.Simple
import Network.HTTP.Client         (responseTimeoutMicro)

-- | Error raised by the Oura client. Mirrors oura_client.OuraAPIError:
-- carries an optional HTTP status code and a message.
data OuraError = OuraError
    { ouraErrorStatus  :: Maybe Int
    , ouraErrorMessage :: Text
    } deriving (Show)

instance Exception OuraError

-- | The set of fetch operations the sync layer needs. Each takes a start and
-- end date (YYYY-MM-DD) and returns the concatenated @data@ array.
data OuraClient = OuraClient
    { getDailySleep             :: Text -> Text -> IO [Value]
    , getDailyReadiness         :: Text -> Text -> IO [Value]
    , getDailyActivity          :: Text -> Text -> IO [Value]
    , getDailyStress            :: Text -> Text -> IO [Value]
    , getDailySpo2              :: Text -> Text -> IO [Value]
    , getDailyResilience        :: Text -> Text -> IO [Value]
    , getDailyCardiovascularAge :: Text -> Text -> IO [Value]
    , getVO2Max                 :: Text -> Text -> IO [Value]
    , getHeartrate              :: Text -> Text -> IO [Value]
    }

baseUrl :: Text
baseUrl = "https://api.ouraring.com"

apiTimeoutMicros :: Int
apiTimeoutMicros = 15 * 1000000

-- | Build the real client bound to a bearer token.
realClient :: Text -> OuraClient
realClient token = OuraClient
    { getDailySleep             = getDated "/v2/usercollection/daily_sleep"
    , getDailyReadiness         = getDated "/v2/usercollection/daily_readiness"
    , getDailyActivity          = getDated "/v2/usercollection/daily_activity"
    , getDailyStress            = getDated "/v2/usercollection/daily_stress"
    , getDailySpo2              = getDated "/v2/usercollection/daily_spo2"
    , getDailyResilience        = getDated "/v2/usercollection/daily_resilience"
    , getDailyCardiovascularAge = getDated "/v2/usercollection/daily_cardiovascular_age"
    , getVO2Max                 = getDated "/v2/usercollection/vO2_max"
    , getHeartrate              = \start end -> getPaged
        "/v2/usercollection/heartrate"
        [ ("start_datetime", dateToDatetime start False)
        , ("end_datetime",   dateToDatetime end True) ]
    }
  where
    getDated path start end = getPaged path
        [("start_date", start), ("end_date", end)]

    -- Follow next_token pagination, concatenating each page's data array.
    getPaged :: Text -> [(Text, Text)] -> IO [Value]
    getPaged path params = go Nothing []
      where
        go mnext acc = do
            let queryParams = params ++ maybe [] (\t -> [("next_token", t)]) mnext
            body <- httpGet path queryParams
            let dataArr = case body of
                    A.Object o -> case lookup "data" o of
                        Just (A.Array a) -> V.toList a
                        _                -> []
                    _ -> []
                nextTok = case body of
                    A.Object o -> case lookup "next_token" o of
                        Just (A.String t) -> Just t
                        _                 -> Nothing
                    _ -> Nothing
                acc' = acc ++ dataArr
            case nextTok of
                Just t  -> go (Just t) acc'
                Nothing -> return acc'

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
            Left (e :: HttpException) ->
                throwIO $ OuraError Nothing ("Request failed: " <> tshow e)
            Right resp -> do
                let status = getResponseStatusCode resp
                if status >= 200 && status < 300
                    then return (getResponseBody resp)
                    else throwIO (mkHttpError status)

    mkHttpError :: Int -> OuraError
    mkHttpError status =
        let base = "HTTP " <> tshow status
            msg = if status == 401
                  then base <> "\nHint: Check your OURA_TOKEN."
                  else base
        in OuraError (Just status) msg

-- | @date_to_datetime_str@ from the Python client.
dateToDatetime :: Text -> Bool -> Text
dateToDatetime dateStr endOfDay =
    dateStr <> "T" <> (if endOfDay then "23:59:59" else "00:00:00")
