{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies      #-}

-- | The login page: a plain HTML form, so unauthenticated visitors get this
-- page and nothing of the dashboard (see docs/login-page-plan.md).
module Handler.Auth
    ( getLoginR
    , postLoginR
    , postLogoutR
    ) where

import Import
import qualified Data.Text as T
import qualified Network.Wai as W
import Network.Wai.Logger (showSockAddr)
import Text.Hamlet (hamletFile)

import LoginThrottle (checkBlocked, noteFailure, noteSuccess)

getLoginR :: Handler Html
getLoginR = do
    authed <- isAuthenticated
    when authed $ redirect HomeR
    loginPage Nothing

postLoginR :: Handler Html
postLoginR = do
    throttle <- getsYesod appLoginThrottle
    ip <- clientIp
    blocked <- liftIO $ checkBlocked throttle ip
    when blocked $ do
        $logWarn $ "Login refused, too many failures from " <> ip
        refuse status429 "Too many attempts. Try again later."
    stored <- getsYesod (appPassword . appSettings)
    when (null stored) $ refuse status500 "Password is not configured."
    ok <- checkPassword . fromMaybe "" =<< lookupPostParam "password"
    if ok
        then do
            liftIO $ noteSuccess throttle ip
            setSession sessionAuthKey "1"
            redirect HomeR
        else do
            liftIO $ noteFailure throttle ip
            $logWarn $ "Failed login from " <> ip
            refuse status401 "Invalid password"
  where
    refuse status msg = sendResponseStatus status =<< loginPage (Just msg)

postLogoutR :: Handler ()
postLogoutR = do
    deleteSession sessionAuthKey
    redirect LoginR

loginPage :: Maybe Text -> Handler Html
loginPage merror = do
    token <- fromMaybe "" . reqToken <$> getRequest
    withUrlRenderer $(hamletFile "templates/login.hamlet")

-- | The address failures are counted against. Behind a reverse proxy
-- (ip-from-header) that is the last X-Forwarded-For hop, the one our proxy
-- appended; earlier hops are client-supplied and could be forged.
clientIp :: Handler Text
clientIp = do
    fromHeader <- getsYesod (appIpFromHeader . appSettings)
    req <- waiRequest
    let socketIp  = pack $ showSockAddr (W.remoteHost req)
        forwarded = do
            guard fromHeader
            hops <- T.splitOn "," . decodeUtf8 <$> lookup "X-Forwarded-For" (W.requestHeaders req)
            T.strip <$> lastMay hops
    return $ fromMaybe socketIp forwarded
