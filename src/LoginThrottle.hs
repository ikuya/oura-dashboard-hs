{-# LANGUAGE NoImplicitPrelude #-}

-- | Per-IP brute-force protection for the login form.
--
-- Failed attempts are kept in memory only; a restart forgets them. An IP with
-- 'maxFailures' failures inside the last 'failureWindow' is refused until the
-- oldest of them ages out.
module LoginThrottle
    ( LoginThrottle
    , newLoginThrottle
    , Failures
    , maxFailures
    , failureWindow
    , isBlocked
    , recordFailure
    , clearFailures
    , checkBlocked
    , noteFailure
    , noteSuccess
    ) where

import ClassyPrelude
import qualified Data.Map.Strict as M
import Data.Time (NominalDiffTime, addUTCTime)

-- | Recent failed login times, keyed by client IP.
type Failures = Map Text [UTCTime]

newtype LoginThrottle = LoginThrottle (TVar Failures)

newLoginThrottle :: IO LoginThrottle
newLoginThrottle = LoginThrottle <$> newTVarIO M.empty

maxFailures :: Int
maxFailures = 5

failureWindow :: NominalDiffTime
failureWindow = 15 * 60

-- | The failures still inside the window at @now@.
recent :: UTCTime -> [UTCTime] -> [UTCTime]
recent now = filter (> addUTCTime (negate failureWindow) now)

isBlocked :: UTCTime -> Text -> Failures -> Bool
isBlocked now ip =
    maybe False ((>= maxFailures) . length . recent now) . M.lookup ip

-- | Record a failure for @ip@, dropping every IP's expired entries on the way
-- so the map only ever holds IPs that failed within the window.
recordFailure :: UTCTime -> Text -> Failures -> Failures
recordFailure now ip =
    M.insertWith (<>) ip [now] . M.filter (not . null) . M.map (recent now)

clearFailures :: Text -> Failures -> Failures
clearFailures = M.delete

checkBlocked :: LoginThrottle -> Text -> IO Bool
checkBlocked (LoginThrottle var) ip = do
    now <- getCurrentTime
    isBlocked now ip <$> readTVarIO var

noteFailure :: LoginThrottle -> Text -> IO ()
noteFailure (LoginThrottle var) ip = do
    now <- getCurrentTime
    atomically $ modifyTVar' var (recordFailure now ip)

noteSuccess :: LoginThrottle -> Text -> IO ()
noteSuccess (LoginThrottle var) ip = atomically $ modifyTVar' var (clearFailures ip)
