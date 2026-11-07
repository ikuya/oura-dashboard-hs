{-# LANGUAGE NoImplicitPrelude #-}

-- | Per-IP brute-force protection for the login form.
--
-- Failed attempts are kept in memory only; a restart forgets them. An IP with
-- 'maxFailures' failures inside the last 'failureWindow' is refused until the
-- oldest of them ages out.
--
-- An attempt is counted as a failure when it is admitted, before the password
-- is checked, and cleared again if it succeeds. Checking and counting in one
-- transaction means concurrent requests cannot all pass the check before any
-- of them is recorded.
module LoginThrottle
    ( LoginThrottle
    , newLoginThrottle
    , Failures
    , maxFailures
    , failureWindow
    , isBlocked
    , recordFailure
    , clearFailures
    , admit
    , beginAttempt
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

-- | Admit an attempt from @ip@, counting it as a failure in advance, or
-- 'Nothing' when the IP is blocked.
admit :: UTCTime -> Text -> Failures -> Maybe Failures
admit now ip failures =
    recordFailure now ip failures <$ guard (not $ isBlocked now ip failures)

-- | Whether an attempt from @ip@ may go ahead; one that may is counted as a
-- failure until 'noteSuccess' clears it.
beginAttempt :: LoginThrottle -> Text -> IO Bool
beginAttempt (LoginThrottle var) ip = do
    now <- getCurrentTime
    atomically $ do
        failures <- readTVar var
        maybe (return False) ((True <$) . writeTVar var) (admit now ip failures)

noteSuccess :: LoginThrottle -> Text -> IO ()
noteSuccess (LoginThrottle var) ip = atomically $ modifyTVar' var (clearFailures ip)
