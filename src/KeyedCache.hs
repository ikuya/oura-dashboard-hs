{-# LANGUAGE NoImplicitPrelude #-}

-- | A single remembered value, tagged with the key it was computed for.
--
-- Meant for a result that is expensive to compute but cheap to fingerprint:
-- the caller derives a key from the state the result depends on, and the
-- cached value is reused for as long as that key stays the same. Kept in
-- memory only; a restart starts empty.
module KeyedCache
    ( KeyedCache
    , newKeyedCache
    , cachedFor
    ) where

import ClassyPrelude

newtype KeyedCache k v = KeyedCache (TVar (Maybe (k, v)))

newKeyedCache :: MonadIO m => m (KeyedCache k v)
newKeyedCache = KeyedCache <$> newTVarIO Nothing

-- | The value remembered for @key@, or else the result of @compute@, which
-- then replaces whatever was remembered. Two callers missing at once both
-- compute; the later write wins, and a key that lost simply misses again.
cachedFor :: (MonadIO m, Eq k) => KeyedCache k v -> k -> m v -> m v
cachedFor (KeyedCache var) key compute = do
    remembered <- readTVarIO var
    case remembered of
        Just (k, v) | k == key -> return v
        _ -> do
            v <- compute
            atomically $ writeTVar var (Just (key, v))
            return v
