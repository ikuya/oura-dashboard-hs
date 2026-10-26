{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Daily database backup, run after the daily sync.
--
-- What it protects is the data Oura cannot give back (the advice history); the
-- rest could be re-synced. Each day keeps one @oura-YYYY-MM-DD.db@ copy, made
-- with @VACUUM INTO@: SQLite writes a consistent, compacted snapshot itself, so
-- it is safe while the web server or the advice job is writing.
module Backup
    ( backupDatabase
    , backupFileName
    , staleBackups
    ) where

import ClassyPrelude
import Control.Monad.Logger    (MonadLogger, logInfo)
import Database.Persist.Sql    (ConnectionPool, PersistValue (..), rawExecute,
                                runSqlPoolNoTransaction)
import System.Directory        (createDirectoryIfMissing, listDirectory,
                                removeFile, removePathForcibly, renameFile)

import DateText (DayText (..), parseDayText)

backupFileName :: DayText -> FilePath
backupFileName (DayText d) = "oura-" <> unpack d <> ".db"

-- | The backups to delete so that only the newest @keep@ remain (at least one,
-- the copy just written). Names not made by 'backupFileName' are left alone.
staleBackups :: Int -> [FilePath] -> [FilePath]
staleBackups keep = drop (max 1 keep) . reverse . sort . filter isBackup
  where
    isBackup name = isJust $
        stripPrefix "oura-" name >>= stripSuffix ".db" >>= parseDayText . pack

-- | Write today's copy into @dir@, replacing one from an earlier run today so
-- the day's last sync is what is kept, then prune to the newest @keep@.
backupDatabase :: (MonadUnliftIO m, MonadLogger m)
               => ConnectionPool -> FilePath -> Int -> DayText -> m ()
backupDatabase pool dir keep today = do
    let target  = dir </> backupFileName today
        partial = target <> ".partial"
    liftIO $ do
        createDirectoryIfMissing True dir
        -- VACUUM INTO refuses an existing file; a leftover is a run that died.
        removePathForcibly partial
    -- VACUUM fails inside a transaction, which runSqlPool would open.
    runSqlPoolNoTransaction
        (rawExecute "VACUUM INTO ?" [PersistText (pack partial)]) pool Nothing
    -- Renaming last means a crash never leaves a truncated oura-*.db behind.
    stale <- liftIO $ do
        renameFile partial target
        stale <- staleBackups keep <$> listDirectory dir
        mapM_ (removeFile . (dir </>)) stale
        return stale
    $logInfo $ "backup written: " <> pack target
            <> (if null stale then "" else ", removed " <> tshow stale)
