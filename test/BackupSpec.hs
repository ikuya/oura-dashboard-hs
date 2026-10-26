{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module BackupSpec (spec) where

import ClassyPrelude
import Test.Hspec
import Control.Monad.Logger    (runNoLoggingT)
import Database.Persist.Sql    (Single (..), rawExecute, rawSql, runSqlPool,
                                toPersistValue)
import Database.Persist.Sqlite (createSqlitePool)
import System.Directory        (createDirectory, getTemporaryDirectory,
                                listDirectory, removePathForcibly)

import Backup

-- | Run with a fresh, empty scratch directory that is removed afterwards.
withScratchDir :: (FilePath -> IO a) -> IO a
withScratchDir = bracket create removePathForcibly
  where
    create = do
        tmp <- getTemporaryDirectory
        let dir = tmp </> "oura-backup-spec"
        removePathForcibly dir
        createDirectory dir
        return dir

spec :: Spec
spec = do
    describe "staleBackups" $ do
        it "drops all but the newest backups" $
            staleBackups 2 [ "oura-2026-10-24.db", "oura-2026-10-26.db"
                           , "oura-2026-10-25.db", "oura-2026-10-23.db" ]
                `shouldBe` ["oura-2026-10-24.db", "oura-2026-10-23.db"]

        it "ignores files it did not name" $
            staleBackups 1 [ "oura-2026-10-26.db", "oura-2026-10-25.db.partial"
                           , "oura-2026-13-45.db", "notes.txt", "oura.db" ]
                `shouldBe` []

        it "always keeps at least the newest" $
            staleBackups 0 ["oura-2026-10-26.db", "oura-2026-10-25.db"]
                `shouldBe` ["oura-2026-10-25.db"]

    describe "backupDatabase" $
        it "writes a readable copy, replaces today's and prunes old ones" $
            withScratchDir $ \dir -> runNoLoggingT $ do
                let backups = dir </> "backup"
                pool <- createSqlitePool (pack (dir </> "src.db")) 1
                runSqlPool (rawExecute "CREATE TABLE t (x INTEGER)" []) pool
                let insert x = runSqlPool (rawExecute "INSERT INTO t VALUES (?)"
                                                      [toPersistValue (x :: Int64)]) pool
                insert 1
                forM_ ["2026-10-23", "2026-10-24", "2026-10-25"] $
                    backupDatabase pool backups 2
                insert 2
                -- A second run on the same day replaces that day's copy.
                backupDatabase pool backups 2 "2026-10-25"
                liftIO $ do
                    sort <$> listDirectory backups
                        `shouldReturn` ["oura-2026-10-24.db", "oura-2026-10-25.db"]
                    copy <- runNoLoggingT $ createSqlitePool
                        (pack (backups </> "oura-2026-10-25.db")) 1
                    rows <- runSqlPool (rawSql "SELECT x FROM t ORDER BY x" []) copy
                    map unSingle rows `shouldBe` [1, 2 :: Int64]
