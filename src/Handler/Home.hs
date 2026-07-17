{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Handler.Home where

import Import

-- | Serve the dashboard's static index.html (mirrors Flask's index() which
-- did send_from_directory("static", "index.html")).
getHomeR :: Handler ()
getHomeR = do
    dir <- appStaticDir . appSettings <$> getYesod
    sendFile typeHtml (dir </> "index.html")
