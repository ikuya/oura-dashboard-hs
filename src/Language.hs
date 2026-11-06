{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The languages an advice report can be written in.
--
-- A closed type rather than a free-form language name, so that every
-- per-language table (the report headings in "Advice") is checked for
-- exhaustiveness when a language is added.
module Language
    ( Language (..)
    , allLanguages
    , languageCode
    , parseLanguage
    ) where

import ClassyPrelude
import Control.Monad.Fail (fail)
import qualified Data.Aeson as A
import qualified Data.Text  as T

data Language = Ja | En
    deriving (Eq, Show, Enum, Bounded)

allLanguages :: [Language]
allLanguages = [minBound .. maxBound]

-- | The ISO 639-1 code, as the settings and the API spell it.
languageCode :: Language -> Text
languageCode Ja = "ja"
languageCode En = "en"

-- | A language from a code, ignoring case and any region subtag, so that a
-- browser's @en-US@ or @ja-JP@ is accepted as well.
parseLanguage :: Text -> Maybe Language
parseLanguage raw = find ((== primary) . languageCode) allLanguages
  where
    primary = T.toLower (T.takeWhile (`notElem` ("-_" :: String)) (T.strip raw))

instance A.FromJSON Language where
    parseJSON = A.withText "Language" $ \t ->
        maybe (fail ("unsupported language: " <> unpack t)) pure (parseLanguage t)

instance A.ToJSON Language where
    toJSON = A.toJSON . languageCode
