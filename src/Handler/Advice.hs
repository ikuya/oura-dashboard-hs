{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies      #-}

-- | Advice endpoints.
-- /api/advice/<seg> is served by getAdviceJobR, which treats seg == "history"
-- as the history-list endpoint and anything else as a job id.
module Handler.Advice where

import Import
import qualified Data.Aeson          as A
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Control.Concurrent  (forkIO)
import Network.HTTP.Types (status202, status400, status404, status502)

import DateText        (DateRange (..), DayText, parseDayText, todayUtc)
import Handler.Common  (jsonBodyOrEmpty)
import Json            (jsonLookup, jsonText)
import Language        (Language, parseLanguage)
import qualified Db
import qualified Advice
import Advice (JobStatus (..), AdviceJob (..), adviceErrorCode,
               adviceErrorDetail, adviceErrorMessage, statusText)

-- POST /api/advice — body @{"lang": "en"}@ picks the report's language;
-- without a supported one it is the @advice-language@ setting.
postAdviceR :: Handler Value
postAdviceR = do
    lang <- requestLang
    today <- todayUtc
    now <- Db.nowIso
    (healthData, previous) <- runDB $
        (,) <$> Advice.buildHealthPayload today <*> Db.getAdviceBefore now

    -- 400 if there is no data at all.
    unless (Advice.hasHealthData healthData) $
        sendStatusJSON status400 $ A.object
            [ "error_code" A..= ("no_data" :: Text)
            , "error" A..= ("no data; run a sync first" :: Text) ]

    let prompt = Advice.buildAdvicePrompt lang previous healthData
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
                    A.object (base ++
                        [ "error_code"   A..= fmap adviceErrorCode (jobError job)
                        , "error_detail" A..= (adviceErrorDetail =<< jobError job)
                        , "error"        A..= maybe "" adviceErrorMessage (jobError job) ])
                _         -> sendStatusJSON status202 (A.object base)

-- GET /api/advice/history
adviceHistoryList :: Handler Value
adviceHistoryList = do
    dates <- runDB Db.getAdviceDates
    returnJson dates

-- GET /api/advice/history/<date>[?at=<saved_at>] — the entry saved at @at@,
-- or the day's latest; @saved_ats@ lists every entry of the day to pick from.
getAdviceEntryR :: Text -> Handler Value
getAdviceEntryR raw = do
    day <- maybe (sendStatusJSON status400
                    (A.object ["error" A..= ("Invalid date format" :: Text)]))
                 return
                 (parseDayText raw)
    entries <- runDB $ Db.getAdviceForDate day
    mat <- lookupGetParam "at"
    let pick = maybe lastMay (\at -> find ((== at) . Db.savedAdviceAt)) mat
    case pick entries of
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
                , "saved_ats"  A..= map Db.savedAdviceAt entries
                , "comparison" A..= comparison
                ]

-- helpers ----------------------------------------------------------------

-- | The @lang@ of the request body, or the configured default when it is
-- missing or not a supported language.
requestLang :: Handler Language
requestLang = do
    body <- jsonBodyOrEmpty
    fallback <- appAdviceLang . appSettings <$> getYesod
    return $ fromMaybe fallback (parseLanguage =<< jsonText =<< jsonLookup "lang" body)

-- | Save advice to advice_history, running in the connection pool.
saveAdviceIO :: ConnectionPool -> DayText -> DayText -> Text -> IO ()
saveAdviceIO pool start end content =
    runSqlPool (Db.saveAdvice start end content) pool
