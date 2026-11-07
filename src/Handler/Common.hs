{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
-- | Common handler functions.
module Handler.Common where

import qualified Data.Aeson as A
import Data.FileEmbed (embedFile)
import Import

-- These handlers embed files in the executable at compile time to avoid a
-- runtime dependency, and for efficiency.

getFaviconR :: Handler TypedContent
getFaviconR = do cacheSeconds $ 60 * 60 * 24 * 30 -- cache for a month
                 return $ TypedContent "image/x-icon"
                        $ toContent $(embedFile "config/favicon.ico")

getRobotsR :: Handler TypedContent
getRobotsR = return $ TypedContent typePlain
                    $ toContent $(embedFile "config/robots.txt")

-- | The request body decoded as JSON, or an empty object when it is missing,
-- not JSON, or malformed.
--
-- 'parseCheckJsonBody' reports those failures in its result, so "silent" stays
-- scoped to a parse failure. The @catch \@SomeException@ this replaces also
-- swallowed unrelated exceptions, including async ones.
jsonBodyOrEmpty :: Handler Value
jsonBodyOrEmpty = do
    result <- parseCheckJsonBody
    return $ case result of
        A.Success v -> v
        A.Error _   -> A.object []
