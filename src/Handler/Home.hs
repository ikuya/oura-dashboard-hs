{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Handler.Home where

import Import

-- | Serve the dashboard's static index.html (mirrors Flask's index() which
-- did send_from_directory("static", "index.html")).
--
-- @no-cache@ for the same reason as the modules it loads (see
-- @Application.revalidating@): without it the browser may heuristically reuse
-- a stale copy from its Last-Modified.
getHomeR :: Handler ()
getHomeR = do
    dir <- appStaticDir . appSettings <$> getYesod
    addHeader "Cache-Control" "no-cache"
    sendFile typeHtml (dir </> "index.html")
