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
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Control.Concurrent  (forkIO)
import Network.HTTP.Types (status202, status400, status404, status502)

import DateText        (DateRange (..), DayText, parseDayText, todayUtc)
import Json            (jsonLookup)
import qualified Db
import qualified Advice
import Advice (JobStatus (..), AdviceJob (..), statusText)

-- POST /api/advice
postAdviceR :: Handler Value
postAdviceR = do
    today <- todayUtc
    now <- Db.nowIso
    (healthData, previous) <- runDB $
        (,) <$> Advice.buildHealthPayload today <*> Db.getAdviceBefore now

    -- 400 if there is no data at all.
    unless (Advice.hasHealthData healthData) $
        sendStatusJSON status400
            (A.object ["error" A..= ("データがありません。まずSyncを実行してください。" :: Text)])

    let prompt = Advice.buildAdvicePrompt previous healthData
        period = fromMaybe A.Null (jsonLookup "period" healthData)
    comparison <- runDB $
        Advice.adviceComparison (Advice.advicePeriod today) previous
    app <- getYesod
    jid <- liftIO $ Advice.createAdviceJob (appAdviceJobs app) period comparison

    -- Fork the worker; it saves to advice_history on success via runDB.
    pool <- appConnPool <$> getYesod
    liftIO $ void $ forkIO $
        Advice.runAdviceJob (appPlainLogger app) (appAdviceJobs app) jid prompt
            (saveAdviceIO pool)

    sendStatusJSON status202 (A.object ["job_id" A..= jid, "status" A..= ("queued" :: Text)])

-- GET /api/advice/<seg> — history list when seg == "history", else job status.
getAdviceJobR :: Text -> Handler Value
getAdviceJobR seg = do
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
                Completed -> returnJson $ A.object (base ++
                    [ "advice"     A..= jobAdvice job
                    , "comparison" A..= jobComparison job ])
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
getAdviceEntryR raw = do
    day <- maybe (sendStatusJSON status400
                    (A.object ["error" A..= ("Invalid date format" :: Text)]))
                 return
                 (parseDayText raw)
    mentry <- runDB $ Db.getAdviceForDate day
    case mentry of
        Nothing -> sendStatusJSON status404
            (A.object ["error" A..= ("No advice for this date" :: Text)])
        Just entry -> do
            let range@(DateRange start end) = Db.savedAdvicePeriod entry
            comparison <- runDB $
                Advice.adviceComparison range =<< Db.getAdviceBefore (Db.savedAdviceAt entry)
            returnJson $ A.object
                [ "advice"     A..= Db.savedAdviceContent entry
                , "period"     A..= A.object ["start" A..= start, "end" A..= end]
                , "saved_at"   A..= Db.savedAdviceAt entry
                , "comparison" A..= comparison
                ]

-- helpers ----------------------------------------------------------------

-- | Save advice to advice_history, running in the connection pool.
saveAdviceIO :: ConnectionPool -> DayText -> DayText -> Text -> IO ()
saveAdviceIO pool start end content =
    runSqlPool (Db.saveAdvice start end content) pool
