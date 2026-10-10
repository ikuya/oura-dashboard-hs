{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The pure core of the login throttle: the window and the threshold.
module LoginThrottleSpec (spec) where

import ClassyPrelude
import Data.Time (addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Test.Hspec

import LoginThrottle

t0 :: UTCTime
t0 = posixSecondsToUTCTime 1700000000

-- | @n@ failures from @ip@, one second apart starting at 't0'.
failures :: Int -> Text -> Failures
failures n ip =
    foldl' (\m i -> recordFailure (addUTCTime (fromIntegral i) t0) ip m) mempty [1 .. n]

spec :: Spec
spec = describe "LoginThrottle" $ do
    let later = addUTCTime 10 t0

    it "allows an IP below the threshold" $
        isBlocked later "1.2.3.4" (failures (maxFailures - 1) "1.2.3.4") `shouldBe` False

    it "blocks an IP at the threshold" $
        isBlocked later "1.2.3.4" (failures maxFailures "1.2.3.4") `shouldBe` True

    it "does not block other IPs" $
        isBlocked later "5.6.7.8" (failures maxFailures "1.2.3.4") `shouldBe` False

    it "unblocks once the failures age out of the window" $
        isBlocked (addUTCTime (failureWindow + 10) t0) "1.2.3.4"
                  (failures maxFailures "1.2.3.4") `shouldBe` False

    it "clears an IP on success" $
        isBlocked later "1.2.3.4"
                  (clearFailures "1.2.3.4" (failures maxFailures "1.2.3.4")) `shouldBe` False

    it "drops expired IPs when recording" $
        length (recordFailure (addUTCTime (failureWindow + 10) t0) "5.6.7.8"
                              (failures maxFailures "1.2.3.4")) `shouldBe` 1
