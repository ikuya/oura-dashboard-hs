{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.HomeSpec (spec) where

import TestImport

spec :: Spec
spec = withApp $ do

    describe "Homepage" $ do
        it "serves the dashboard index.html" $ do
            get HomeR
            statusIs 200
            -- index.html references the frontend assets by fixed path.
            bodyContains "/static/main.js"

        it "serves static assets under /static" $ do
            request $ setUrl ("/static/style.css" :: Text)
            statusIs 200
