{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Daily sync CLI, ported from daily_sync.py.
--
-- Runs an incremental sync with a 7-day backfill and exits 1 when any metric
-- errored. Shares the settings/.env loading with the web app but builds only a
-- DB pool (no full foundation). Logs go wherever LOG_FILE points, defaulting to
-- stdout; see Logging.
module DailySync (dailySyncMain) where

import ClassyPrelude
import Control.Monad.Logger        (LogLevel (..), LoggingT, defaultLogStr,
                                    logError, logInfo, runLoggingT)
import Database.Persist.Sqlite     (createSqlitePool, runSqlPool, runMigrationSilent, sqlDatabase, sqlPoolSize)
import Data.Time.LocalTime        (utcToZonedTime, hoursToTimeZone)
import qualified Data.Map.Strict  as M
import System.Exit                (exitWith, ExitCode (..))
import System.Log.FastLogger      (LoggerSet, flushLogStr, pushLogStr, toLogStr)

import Application (getAppSettings)
import Logging     (newAppLoggerSet, newTimestamp, setGlobalLoggerSet)
import Settings    (AppSettings, appDatabaseConf, appLogFile, appOuraToken,
                    appShouldLogAll)
import Model       (migrateAll)
import Oura        (realClient)
import Sync        (runSync, SyncResult (..))

backfillDays :: Int
backfillDays = 7

todayJst :: IO Text
todayJst = do
    now <- getCurrentTime
    let jst = utcToZonedTime (hoursToTimeZone 9) now
    return $ pack (formatTime defaultTimeLocale "%Y-%m-%d" jst)

dailySyncMain :: IO ()
dailySyncMain = do
    settings <- getAppSettings
    loggerSet' <- newAppLoggerSet (appLogFile settings)
    -- The Oura client logs from plain IO through this same set.
    setGlobalLoggerSet loggerSet'
    code <- runLog (appShouldLogAll settings) loggerSet' (dailySync settings)
    flushLogStr loggerSet'
    exitWith code

-- | Run a LoggingT against the app's logger set. Each line is prefixed with the
-- local time, the way Yesod prefixes the web app's lines. Mirrors Foundation's
-- shouldLogIO: Debug (which includes persistent's per-query SQL logging) needs
-- YESOD_SHOULD_LOG_ALL.
runLog :: Bool -> LoggerSet -> LoggingT IO a -> IO a
runLog logAll ls act = do
    getTime <- newTimestamp
    runLoggingT act $ \loc src level msg ->
        when (logAll || level >= LevelInfo) $ do
            ts <- getTime
            pushLogStr ls (toLogStr ts <> " " <> defaultLogStr loc src level msg)

dailySync :: AppSettings -> LoggingT IO ExitCode
dailySync settings = do
    let token = appOuraToken settings
    if null token
        then do
            $logError "OURA_TOKEN not set"
            return (ExitFailure 1)
        else do
            $logInfo $ "starting daily sync (backfill_days="
                     <> tshow backfillDays <> ")"
            today <- liftIO todayJst
            let client = realClient token
            pool <- createSqlitePool
                (sqlDatabase (appDatabaseConf settings))
                (sqlPoolSize (appDatabaseConf settings))
            -- Apply migrations first (mirrors daily_sync.py calling db.init_db(),
            -- which adds the sync_log.last_synced_at column if missing).
            _ <- runSqlPool (runMigrationSilent migrateAll) pool
            result <- flip runSqlPool pool $
                runSync today client Nothing Nothing Nothing backfillDays

            -- Individual failures are already logged by Sync.tryOura.
            $logInfo "daily sync done"
            return $ if M.null (syncErrors result)
                     then ExitSuccess
                     else ExitFailure 1
