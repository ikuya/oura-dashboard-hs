{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE InstanceSigs #-}

module Foundation where

import Import.NoFoundation
import Data.Kind            (Type)
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Text.Hamlet          (hamletFile)
import Text.Jasmine         (minifym)
import Yesod.Default.Util   (addStaticContentExternal)
import Yesod.Core.Types     (Logger)
import System.Log.FastLogger (LoggerSet)
import Control.Monad.Logger (LogSource)
import Crypto.BCrypt        (validatePassword)
import qualified Data.Aeson as A
import Oura                 (OuraClient)
import Advice               (AdviceJobs)
import LoginThrottle        (LoginThrottle)
import Logging              (AppLog)
import qualified Yesod.Core.Unsafe as Unsafe

-- | The foundation datatype for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { appSettings    :: AppSettings
    , appStatic      :: Static -- ^ Settings for static file serving.
    , appConnPool    :: ConnectionPool -- ^ Database connection pool.
    , appHttpManager :: Manager
    , appLogger      :: Logger
    , appAccessLoggerSet :: LoggerSet
      -- ^ Destination for wai-extra's Apache-format request lines. Separate
      -- from 'appLogger' so the two timestamp formats don't interleave in one
      -- file; equal to the app's own logger set when ACCESS_LOG_FILE is unset.
    , appOuraClientOverride :: Maybe OuraClient
      -- ^ Test seam: when set, the sync handler uses this client instead of
      -- building a real one from OURA_TOKEN (mirrors the Python test mocking
      -- run_sync). 'Nothing' in production.
    , appAdviceJobs  :: AdviceJobs
      -- ^ In-process advice job state (non-persistent, like Python's
      -- Lock-guarded _advice_jobs dict).
    , appPlainLogger :: AppLog
      -- ^ Log destination for the code that runs outside 'MonadLogger': the
      -- Oura client's IO fetches and the forked advice worker.
    , appLoginThrottle :: LoginThrottle
      -- ^ Recent failed logins per IP, for brute-force protection.
    }

-- This is where we define all of the routes in our application. For a full
-- explanation of the syntax, please see:
-- http://www.yesodweb.com/book/routing-and-handlers
--
-- Note that this is really half the story; in Application.hs, mkYesodDispatch
-- generates the rest of the code. Please see the following documentation
-- for an explanation for this split:
-- http://www.yesodweb.com/book/scaffolding-and-the-site-template#scaffolding-and-the-site-template_foundation_and_application_modules
--
-- This function also generates the following type synonyms:
-- type Handler = HandlerFor App
-- type Widget = WidgetFor App ()
mkYesodData "App" $(parseRoutesFile "config/routes.yesodroutes")

-- | A convenient synonym for creating forms.
type Form x = Html -> MForm (HandlerFor App) (FormResult x, Widget)

-- | A convenient synonym for database access functions.
type DB a = forall (m :: Type -> Type).
    (MonadUnliftIO m) => ReaderT SqlBackend m a

-- Please see the documentation for the Yesod typeclass. There are a number
-- of settings which can be configured by overriding methods here.
instance Yesod App where
    -- Controls the base of generated URLs. For more information on modifying,
    -- see: https://github.com/yesodweb/yesod/wiki/Overriding-approot
    approot :: Approot App
    approot = ApprootRequest $ \app req ->
        case appRoot $ appSettings app of
            Nothing -> getApprootText guessApproot app req
            Just root -> root

    -- Store session data on the client in encrypted cookies,
    -- session idle timeout is 7 days (personal use). SameSite=Lax keeps the
    -- cookie off cross-site POSTs; Secure is opt-in until the site has HTTPS.
    makeSessionBackend :: App -> IO (Maybe SessionBackend)
    makeSessionBackend app = secureOnly $ laxSameSiteSessions $
        Just <$> defaultClientSessionBackend
            (7 * 24 * 60)    -- timeout in minutes (7 days)
            "config/client_session_key.aes"
      where
        secureOnly | appSecureCookies (appSettings app) = sslOnlySessions
                   | otherwise                          = id

    -- CSRF: the token travels in the XSRF-TOKEN cookie; api.js echoes it in
    -- the X-XSRF-TOKEN header and the login form in a hidden _token field.
    yesodMiddleware :: ToTypedContent res => Handler res -> Handler res
    yesodMiddleware handler = do
        https <- getsYesod (appSecureCookies . appSettings)
        (if https then sslOnlyMiddleware (365 * 24 * 60) else id)
            $ defaultCsrfMiddleware
            $ defaultYesodMiddleware handler

    -- Unauthenticated visitors see the login page and nothing else; see
    -- 'routeAccess' for what each route answers instead.
    isAuthorized :: Route App -> Bool -> Handler AuthResult
    isAuthorized route _ = do
        authed <- isAuthenticated
        case routeAccess route of
            _ | authed -> return Authorized
            Public     -> return Authorized
            Page       -> redirect LoginR
            Asset      -> notFound
            Api        -> sendStatusJSON status401
                              (A.object ["error" A..= ("Unauthorized" :: Text)])

    defaultLayout :: Widget -> Handler Html
    defaultLayout widget = do
        mmsg <- getMessage

        pc <- widgetToPageContent $ do
            $(widgetFile "default-layout")
        withUrlRenderer $(hamletFile "templates/default-layout-wrapper.hamlet")

    -- This function creates static content files in the static folder
    -- and names them based on a hash of their content. This allows
    -- expiration dates to be set far in the future without worry of
    -- users receiving stale content.
    addStaticContent
        :: Text  -- ^ The file extension
        -> Text -- ^ The MIME content type
        -> LByteString -- ^ The contents of the file
        -> Handler (Maybe (Either Text (Route App, [(Text, Text)])))
    addStaticContent ext mime content = do
        master <- getYesod
        let staticDir = appStaticDir $ appSettings master
        addStaticContentExternal
            minifym
            genFileName
            staticDir
            (StaticR . flip StaticRoute [])
            ext
            mime
            content
      where
        -- Generate a unique filename based on the content itself
        genFileName lbs = "autogen-" ++ base64md5 lbs

    -- What messages should be logged. Info and above are kept in production so
    -- the sync/advice records are auditable; Debug needs should-log-all.
    shouldLogIO :: App -> LogSource -> LogLevel -> IO Bool
    shouldLogIO app _source level =
        return $
        appShouldLogAll (appSettings app)
            || level >= LevelInfo

    makeLogger :: App -> IO Logger
    makeLogger = return . appLogger

-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB :: SqlPersistT Handler a -> Handler a
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master

instance YesodPersistRunner App where
    getDBRunner :: Handler (DBRunner App, Handler ())
    getDBRunner = defaultGetDBRunner appConnPool

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage :: App -> [Lang] -> FormMessage -> Text
    renderMessage _ _ = defaultFormMessage

-- Useful when writing code that is re-usable outside of the Handler context.
instance HasHttpManager App where
    getHttpManager :: App -> Manager
    getHttpManager = appHttpManager

unsafeHandler :: App -> Handler a -> IO a
unsafeHandler = Unsafe.fakeHandlerGetLogger appLogger

-- Auth -------------------------------------------------------------------

-- | Session key marking an authenticated session.
sessionAuthKey :: Text
sessionAuthKey = "authenticated"

-- | Whether the current session is authenticated.
isAuthenticated :: Handler Bool
isAuthenticated = isJust <$> lookupSession sessionAuthKey

-- | How a route answers an unauthenticated request.
data Access
    = Public  -- ^ Served to anyone.
    | Page    -- ^ Redirect to the login page.
    | Asset   -- ^ 404, so scanners cannot tell the file exists.
    | Api     -- ^ 401 JSON, which api.js turns into a trip to the login page.

-- | Deliberately no wildcard: a new route must pick its access level.
routeAccess :: Route App -> Access
routeAccess route = case route of
    StaticR _        -> Asset
    FaviconR         -> Public
    RobotsR          -> Public
    HomeR            -> Page
    LoginR           -> Public
    LogoutR          -> Public
    MetricsR         -> Api
    MetricR _        -> Api
    HeartrateR       -> Api
    SleepPeriodsR    -> Api
    SyncStatusR      -> Api
    SyncR            -> Api
    AdviceEntryR _   -> Api
    AdviceR          -> Api
    AdviceJobR _     -> Api

-- | Validate a plaintext password against the configured bcrypt hash.
checkPassword :: Text -> Handler Bool
checkPassword plain = do
    stored <- appPassword . appSettings <$> getYesod
    return $ validatePassword (encodeUtf8 stored) (encodeUtf8 plain)
