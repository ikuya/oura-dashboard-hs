{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | 'parseDayText' is the only gate between untrusted date text and the
-- partial 'parseDay', so its rejections are worth pinning down.
module DateTextSpec (spec) where

import ClassyPrelude
import Test.Hspec

import DateText

spec :: Spec
spec = describe "parseDayText" $ do
    it "accepts a well-formed day" $
        parseDayText "2024-01-31" `shouldBe` Just (DayText "2024-01-31")

    it "accepts a leap day that exists" $
        parseDayText "2024-02-29" `shouldBe` Just (DayText "2024-02-29")

    it "rejects a well-shaped but impossible date" $ do
        parseDayText "1999-13-45" `shouldBe` Nothing
        parseDayText "2020-02-30" `shouldBe` Nothing
        parseDayText "2023-02-29" `shouldBe` Nothing
        parseDayText "2020-00-10" `shouldBe` Nothing

    -- Unpadded or short components would break the text ordering DayText
    -- relies on, so they are rejected even though they name a real day.
    it "rejects non-canonical shapes" $ do
        parseDayText "2024-1-5" `shouldBe` Nothing
        parseDayText "24-01-05" `shouldBe` Nothing
        parseDayText "2024/01/05" `shouldBe` Nothing
        parseDayText "" `shouldBe` Nothing

    it "round-trips through parseDay" $
        (formatDay . parseDay <$> parseDayText "2024-01-31")
            `shouldBe` Just (DayText "2024-01-31")
