{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies      #-}

-- | Advice endpoints, ported from app.py.
-- /api/advice/<seg> is served by getAdviceJobR, which treats seg == "history"
-- as the history-list endpoint and anything else as a job id.
module Handler.Advice where

import Import
import qualified Data.Aeson          as A
import qualified Data.HashMap.Strict as HM
import qualified Data.Text           as T
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Control.Concurrent  (forkIO)
import Data.Char           (isDigit)
import Network.HTTP.Types (status202, status400, status404, status502)

import qualified Db
import qualified Advice
import Advice (JobStatus (..), AdviceJob (..), statusText)
import Handler.Api (todayStr)

-- POST /api/advice
postAdviceR :: Handler Value
postAdviceR = do
    requireAuth
    today <- todayStr
    healthData <- runDB $ Advice.buildHealthPayload today 14

    -- 400 if there is no data at all (any metric list non-empty).
    let hasData = case lookupJson "metrics" healthData of
            Just (A.Object ms) -> any nonEmptyArr (HM.elems ms)
            _                  -> False
    unless hasData $
        sendStatusJSON status400
            (A.object ["error" A..= ("データがありません。まずSyncを実行してください。" :: Text)])

    let prompt = Advice.buildAdvicePrompt healthData
        period = fromMaybe A.Null (lookupJson "period" healthData)
    app <- getYesod
    jid <- liftIO $ Advice.createAdviceJob (appAdviceJobs app) period

    -- Fork the worker; it saves to advice_history on success via runDB.
    pool <- appConnPool <$> getYesod
    liftIO $ void $ forkIO $
        Advice.runAdviceJob (appAdviceJobs app) jid prompt (saveAdviceIO pool)

    sendStatusJSON status202 (A.object ["job_id" A..= jid, "status" A..= ("queued" :: Text)])

-- GET /api/advice/<seg> — history list when seg == "history", else job status.
getAdviceJobR :: Text -> Handler Value
getAdviceJobR seg = do
    requireAuth
    if seg == "history"
        then adviceHistoryList
        else adviceJobStatus seg

adviceJobStatus :: Text -> Handler Value
adviceJobStatus jid = do
    app <- getYesod
    mjob <- liftIO $ Advice.getJob (appAdviceJobs app) jid
    case mjob of
        Nothing -> sendStatusJSON status404 (A.object ["error" A..= ("Job not found" :: Text)])
        Just job -> do
            let base = [ "job_id" A..= jobId job
                       , "status" A..= statusText (jobStatus job)
                       , "period" A..= jobPeriod job ]
            case jobStatus job of
                Completed -> returnJson $ A.object (base ++ ["advice" A..= jobAdvice job])
                Failed    -> sendStatusJSON status502 $
                    A.object (base ++ ["error" A..= fromMaybe "" (jobError job)])
                _         -> sendStatusJSON status202 (A.object base)

-- GET /api/advice/history
adviceHistoryList :: Handler Value
adviceHistoryList = do
    dates <- runDB Db.getAdviceDates
    returnJson dates

-- GET /api/advice/history/<date>
getAdviceEntryR :: Text -> Handler Value
getAdviceEntryR day = do
    requireAuth
    unless (isIsoDate day) $
        sendStatusJSON status400 (A.object ["error" A..= ("Invalid date format" :: Text)])
    mentry <- runDB $ Db.getAdviceForDate day
    case mentry of
        Nothing -> sendStatusJSON status404
            (A.object ["error" A..= ("No advice for this date" :: Text)])
        Just entry -> returnJson $ A.object
            [ "advice"   A..= fromMaybe A.Null (lookupJson "content" entry)
            , "period"   A..= A.object
                [ "start" A..= fromMaybe A.Null (lookupJson "period_start" entry)
                , "end"   A..= fromMaybe A.Null (lookupJson "period_end" entry) ]
            , "saved_at" A..= fromMaybe A.Null (lookupJson "saved_at" entry)
            ]

-- helpers ----------------------------------------------------------------

lookupJson :: Text -> A.Value -> Maybe A.Value
lookupJson k (A.Object o) = HM.lookup k o
lookupJson _ _            = Nothing

nonEmptyArr :: A.Value -> Bool
nonEmptyArr (A.Array a) = not (null a)
nonEmptyArr _           = False

-- | Match YYYY-MM-DD exactly (app.py's re.fullmatch).
isIsoDate :: Text -> Bool
isIsoDate t = case T.splitOn "-" t of
    [y, m, d] -> T.length y == 4 && T.length m == 2 && T.length d == 2
                 && all (T.all isDigit) [y, m, d]
    _ -> False

-- | Save advice to advice_history, running in the connection pool.
saveAdviceIO :: ConnectionPool -> Text -> Text -> Text -> IO ()
saveAdviceIO pool start end content =
    runSqlPool (Db.saveAdvice start end content) pool
