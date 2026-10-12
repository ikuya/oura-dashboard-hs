{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Scheduled advice CLI, run from cron a few days a week.
--
-- Generates advice over the same 14 days as the web's Advice button and saves
-- it to advice_history, so the result shows up in the history list. Unlike a
-- web job it runs in the foreground and exits 1 on failure (no data, or the
-- claude CLI failing), so cron's exit status tells the two apart. Run it after
-- the daily sync so the last night is included.
module ScheduledAdvice (scheduledAdviceMain) where

import ClassyPrelude
import Control.Monad.Logger        (LoggingT, logError, logInfo)
import Database.Persist.Sqlite     (createSqlitePool, runSqlPool, runMigrationSilent, sqlDatabase, sqlPoolSize)
import Data.Time.Clock            (diffUTCTime)
import Data.Time.LocalTime        (hoursToTimeZone)
import GHC.IO.Encoding            (setFileSystemEncoding, setForeignEncoding,
                                   setLocaleEncoding, utf8)
import System.Exit                (exitWith, ExitCode (..))
import System.Log.FastLogger      (flushLogStr)

import Advice      (buildAdvicePrompt, buildHealthPayload, generateAdvice,
                    hasHealthData)
import Application (getAppSettings)
import DateText    (DayText (..), addDaysT, todayIn)
import Db          (saveAdvice)
import Logging     (newAppLoggerSet, runLog)
import Model       (migrateAll)
import Settings    (AppSettings, appDatabaseConf, appLogFile, appShouldLogAll)

-- | The window the web's Advice button analyses.
adviceDays :: Int
adviceDays = 14

scheduledAdviceMain :: IO ()
scheduledAdviceMain = do
    -- cron may start us without LANG, and GHC would then read the claude CLI's
    -- Japanese output (and pass the prompt) as ASCII and fail.
    setLocaleEncoding utf8
    setFileSystemEncoding utf8
    setForeignEncoding utf8
    settings <- getAppSettings
    loggerSet' <- newAppLoggerSet (appLogFile settings)
    code <- runLog (appShouldLogAll settings) loggerSet' (scheduledAdvice settings)
    flushLogStr loggerSet'
    exitWith code

scheduledAdvice :: AppSettings -> LoggingT IO ExitCode
scheduledAdvice settings = do
    -- JST like DailySync, so the window ends on the day the sync just filled.
    today <- todayIn (hoursToTimeZone 9)
    let start = addDaysT (negate (fromIntegral adviceDays - 1)) today
    $logInfo $ "starting scheduled advice for " <> unDayText start <> ".." <> unDayText today
    pool <- createSqlitePool
        (sqlDatabase (appDatabaseConf settings))
        (sqlPoolSize (appDatabaseConf settings))
    _ <- runSqlPool (runMigrationSilent migrateAll) pool
    healthData <- runSqlPool (buildHealthPayload today adviceDays) pool
    if not (hasHealthData healthData)
        then do
            $logError "no metric data in the advice window; run a sync first"
            return (ExitFailure 1)
        else do
            started <- liftIO getCurrentTime
            result <- liftIO $ generateAdvice (buildAdvicePrompt healthData)
            case result of
                Left msg -> do
                    $logError $ "scheduled advice failed: " <> msg
                    return (ExitFailure 1)
                Right advice -> do
                    runSqlPool (saveAdvice start today advice) pool
                    finished <- liftIO getCurrentTime
                    $logInfo $ "scheduled advice saved in "
                             <> tshow (diffUTCTime finished started)
                    return ExitSuccess
