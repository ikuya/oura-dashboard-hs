{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

-- | Daily sync CLI, ported from daily_sync.py.
--
-- Runs an incremental sync with a 7-day backfill, logs JST-timestamped output,
-- and exits 1 when any metric errored. Shares the settings/.env loading with the
-- web app but builds only a DB pool (no full foundation).
module DailySync (dailySyncMain) where

import ClassyPrelude
import Control.Monad.Logger        (runNoLoggingT)
import Database.Persist.Sqlite     (createSqlitePool, runSqlPool, runMigrationSilent, sqlDatabase, sqlPoolSize)
import Data.Time.Format           (formatTime, defaultTimeLocale)
import Data.Time.LocalTime        (utcToZonedTime, hoursToTimeZone)
import qualified Data.Map.Strict  as M
import System.Exit                (exitWith, ExitCode (..))
import System.IO                  (hPutStrLn, stderr)

import Application (getAppSettings)
import Settings    (appDatabaseConf, appOuraToken)
import Model       (migrateAll)
import Oura        (realClient)
import Sync        (runSync, SyncResult (..))

backfillDays :: Int
backfillDays = 7

-- | JST (UTC+9) timestamp in ISO-8601, matching daily_sync.py's
-- datetime.now(JST).isoformat().
jstNow :: IO Text
jstNow = do
    now <- getCurrentTime
    let jst = utcToZonedTime (hoursToTimeZone 9) now
    return $ pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z" jst)

todayJst :: IO Text
todayJst = do
    now <- getCurrentTime
    let jst = utcToZonedTime (hoursToTimeZone 9) now
    return $ pack (formatTime defaultTimeLocale "%Y-%m-%d" jst)

dailySyncMain :: IO ()
dailySyncMain = do
    settings <- getAppSettings
    let token = appOuraToken settings
    when (null token) $ do
        hPutStrLn stderr "ERROR: OURA_TOKEN not set"
        exitWith (ExitFailure 1)

    started <- jstNow
    putStrLn ("[" <> started <> "] Starting daily sync (backfill_days="
              <> tshow backfillDays <> ")")

    today <- todayJst
    let client = realClient token
    pool <- runNoLoggingT $ createSqlitePool
        (sqlDatabase (appDatabaseConf settings))
        (sqlPoolSize (appDatabaseConf settings))
    -- Apply migrations first (mirrors daily_sync.py calling db.init_db(),
    -- which adds the sync_log.last_synced_at column if missing).
    _ <- runNoLoggingT $ runSqlPool (runMigrationSilent migrateAll) pool
    result <- runNoLoggingT $ flip runSqlPool pool $
        runSync today client Nothing Nothing Nothing backfillDays

    forM_ (M.toList (syncedCounts result)) $ \(metric, count) ->
        putStrLn ("  " <> metric <> ": " <> tshow count <> " rows")
    unless (M.null (syncErrors result)) $ do
        putStrLn "Errors:"
        forM_ (M.toList (syncErrors result)) $ \(metric, msg) ->
            hPutStrLn stderr ("  " <> unpack metric <> ": " <> unpack msg)

    finished <- jstNow
    putStrLn ("[" <> finished <> "] Done")
    if M.null (syncErrors result)
        then return ()
        else exitWith (ExitFailure 1)
