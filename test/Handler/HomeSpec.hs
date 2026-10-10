{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.HomeSpec (spec) where

import TestImport

spec :: Spec
spec = withApp $ do

    describe "Homepage" $ do
        it "serves the dashboard index.html once logged in" $ do
            login
            get HomeR
            statusIs 200
            -- index.html references the frontend assets by fixed path.
            bodyContains "/static/main.js"

        it "serves static assets under /static once logged in" $ do
            login
            request $ setUrl ("/static/style.css" :: Text)
            statusIs 200

    describe "Unauthenticated" $ do
        it "redirects the homepage to the login page" $ do
            get HomeR
            statusIs 303
            redirectsTo LoginR

        it "hides static assets behind a 404" $ do
            request $ setUrl ("/static/main.js" :: Text)
            statusIs 404
            request $ setUrl ("/static/index.html" :: Text)
            statusIs 404
