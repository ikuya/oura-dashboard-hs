{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Log destination setup, shared by the web app and the daily sync CLI.
--
-- Both entry points write to their own file under @log@ (they must not share
-- one, since each process holds its own buffered handle). The path comes from
-- the @LOG_FILE@ setting; when it is unset, logs go to stdout as before.
--
-- Rotation is left to logrotate; see README for a sample config. fast-logger's
-- rotating 'LogFile' type is not usable here because Yesod's logger and
-- wai-extra's request logger both require a 'LoggerSet'.
module Logging
    ( newAppLoggerSet
    , newTimestamp
    , AppLog (..)
    , newAppLog
    ) where

import ClassyPrelude
import Control.Monad.Logger (LogLevel (..))
import System.Directory     (createDirectoryIfMissing)
import System.FilePath      (takeDirectory)
import System.IO            (hPutStrLn)
import System.Log.FastLogger
    ( FormattedTime, LoggerSet, defaultBufSize, newFileLoggerSet
    , newStdoutLoggerSet, newTimeCache, pushLogStrLn, toLogStr )

-- | Build the logger set for a log file path. 'Nothing' (or an empty path)
-- means stdout.
--
-- Logging must never take the process down: if the directory or file cannot be
-- opened we report the reason on stderr once and fall back to stdout, rather
-- than failing startup.
newAppLoggerSet :: Maybe FilePath -> IO LoggerSet
newAppLoggerSet mpath = case mpath of
    Just path | not (null path) -> do
        r <- try $ do
            createDirectoryIfMissing True (takeDirectory path)
            newFileLoggerSet defaultBufSize path
        case r of
            Right ls -> return ls
            Left (e :: SomeException) -> do
                hPutStrLn stderr $
                    "WARNING: cannot write log file " ++ path
                    ++ " (" ++ show e ++ "); falling back to stdout"
                stdoutSet
    _ -> stdoutSet
  where
    stdoutSet = newStdoutLoggerSet defaultBufSize

-- Logging from plain IO ---------------------------------------------------

-- | How a plain-'IO' code path writes a log line.
--
-- Some code that needs to log has no 'MonadLogger' in scope: the
-- 'Oura.OuraClient' record is nine @IO@ functions, and advice jobs are forked
-- with 'forkIO'. Those paths take this handle from whoever built them, so the
-- log destination stays an ordinary value rather than process-wide state.
newtype AppLog = AppLog { writeLog :: LogLevel -> Text -> IO () }

-- | Log to a logger set, with the same timestamp-first layout as the
-- monad-logger paths so all lines in a file read alike. Holds its own time
-- cache, so build one per entry point rather than one per message.
newAppLog :: LoggerSet -> IO AppLog
newAppLog ls = do
    getTime <- newTimestamp
    return $ AppLog $ \level msg -> do
        ts <- getTime
        pushLogStrLn ls $
            toLogStr ts <> toLogStr (" [" <> levelName level <> "] " <> msg)

-- | A cached local-time formatter. The cache reformats at most once a second.
newTimestamp :: IO (IO FormattedTime)
newTimestamp = newTimeCache "%Y-%m-%d %H:%M:%S"

levelName :: LogLevel -> Text
levelName LevelDebug     = "Debug"
levelName LevelInfo      = "Info"
levelName LevelWarn      = "Warn"
levelName LevelError     = "Error"
levelName (LevelOther t) = t
