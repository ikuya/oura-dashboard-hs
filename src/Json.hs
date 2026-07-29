{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Accessors for the loosely-typed JSON that flows through the app: Oura API
-- payloads and the @data_json@ blobs stored per row. The sync, advice and
-- handler layers all reach into those values, so the lookups live here once
-- instead of being re-spelled as nested @case@ expressions in every module.
module Json
    ( jsonLookup
    , jsonText
    , jsonDouble
    , jsonInt
    , jsonArray
    ) where

import ClassyPrelude
import Data.Aeson                 (Value (..))
import qualified Data.Aeson.Key    as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector       as V

-- | Look up a key, if the value is an object.
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup k (Object o) = KM.lookup (K.fromText k) o
jsonLookup _ _          = Nothing

jsonText :: Value -> Maybe Text
jsonText (String t) = Just t
jsonText _          = Nothing

jsonDouble :: Value -> Maybe Double
jsonDouble (Number n) = Just (realToFrac n)
jsonDouble _          = Nothing

-- | A JSON number rounded to an integral type (bpm and friends).
jsonInt :: Integral a => Value -> Maybe a
jsonInt (Number n) = Just (round n)
jsonInt _          = Nothing

jsonArray :: Value -> Maybe [Value]
jsonArray (Array a) = Just (V.toList a)
jsonArray _         = Nothing
