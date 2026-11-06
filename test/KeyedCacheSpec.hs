{-# LANGUAGE NoImplicitPrelude #-}

module KeyedCacheSpec (spec) where

import ClassyPrelude
import Test.Hspec

import KeyedCache

-- | A computation that counts its runs and returns the run number.
counter :: IO (IO Int)
counter = do
    runs <- newIORef (0 :: Int)
    return $ atomicModifyIORef' runs (\n -> (n + 1, n + 1))

spec :: Spec
spec = describe "KeyedCache" $ do
    it "computes once while the key stays the same" $ do
        cache <- newKeyedCache
        compute <- counter
        a <- cachedFor cache "k1" compute
        b <- cachedFor cache "k1" compute
        (a, b) `shouldBe` (1, 1 :: Int)

    it "recomputes when the key changes" $ do
        cache <- newKeyedCache
        compute <- counter
        results <- mapM (\k -> cachedFor cache k compute) ["k1", "k2", "k2", "k1" :: String]
        results `shouldBe` [1, 2, 2, 3]
