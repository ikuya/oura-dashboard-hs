{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module LanguageSpec (spec) where

import ClassyPrelude
import Test.Hspec
import qualified Data.Aeson as A

import Language (Language (..), allLanguages, languageCode, parseLanguage)

spec :: Spec
spec = describe "parseLanguage" $ do
    it "reads back every language's code" $
        forM_ allLanguages $ \l -> parseLanguage (languageCode l) `shouldBe` Just l

    it "ignores case and a region subtag" $ do
        parseLanguage "en-US" `shouldBe` Just En
        parseLanguage "JA_jp" `shouldBe` Just Ja
        parseLanguage " ja " `shouldBe` Just Ja

    it "rejects an unsupported or empty code" $ do
        parseLanguage "fr" `shouldBe` Nothing
        parseLanguage "" `shouldBe` Nothing
        parseLanguage "english" `shouldBe` Nothing

    it "fails to decode an unsupported language from settings" $
        (A.fromJSON (A.String "de") :: A.Result Language)
            `shouldSatisfy` \r -> case r of A.Error _ -> True; A.Success _ -> False
