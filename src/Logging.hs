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
    , setGlobalLoggerSet
    , logGlobal
    ) where

import ClassyPrelude
import Control.Monad.Logger (LogLevel (..))
import Data.Time            (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory     (createDirectoryIfMissing)
import System.FilePath      (takeDirectory)
import System.IO            (hPutStrLn, stderr)
import System.IO.Unsafe     (unsafePerformIO)
import System.Log.FastLogger
    ( LoggerSet, defaultBufSize, newFileLoggerSet, newStdoutLoggerSet
    , pushLogStrLn, toLogStr )

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

-- Global logger set ------------------------------------------------------

-- | Some code that needs to log runs in plain 'IO' with no 'MonadLogger' in
-- scope: the 'Oura.OuraClient' record is nine @IO@ functions, and advice jobs
-- are forked with 'forkIO'. Those paths write here instead. Unset until an
-- entry point installs a logger set, in which case messages are dropped.
globalLoggerSet :: IORef (Maybe LoggerSet)
globalLoggerSet = unsafePerformIO (newIORef Nothing)
{-# NOINLINE globalLoggerSet #-}

setGlobalLoggerSet :: LoggerSet -> IO ()
setGlobalLoggerSet = writeIORef globalLoggerSet . Just

-- | Log a message from an 'IO' context, formatted like monad-logger's default
-- output so both paths interleave readably in one file.
logGlobal :: LogLevel -> Text -> IO ()
logGlobal level msg = do
    mls <- readIORef globalLoggerSet
    case mls of
        Nothing -> return ()
        Just ls -> do
            now <- getCurrentTime
            let ts = pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z" now)
            pushLogStrLn ls $ toLogStr
                ("[" <> levelName level <> "] " <> msg <> " @(" <> ts <> ")")

levelName :: LogLevel -> Text
levelName LevelDebug     = "Debug"
levelName LevelInfo      = "Info"
levelName LevelWarn      = "Warn"
levelName LevelError     = "Error"
levelName (LevelOther t) = t
