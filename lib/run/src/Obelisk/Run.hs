{-# LANGUAGE CPP #-}
#if defined(IPROUTE_SUPPORTED)
{-# LANGUAGE TemplateHaskell #-}
#endif

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- Due to instance HasJS x (EventWriterT t w m)
module Obelisk.Run where

import Prelude hiding ((.), id)

import Control.Monad.IO.Class
import Control.Category
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Lens ((%~), (^?), _Just, _Right)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BSLC
import qualified Data.ByteString.UTF8 as BSUTF8
import Data.Foldable
import Data.Functor.Identity
import Data.List (uncons)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Semigroup ((<>))
import Data.Streaming.Network (bindPortTCP)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time.Clock (getCurrentTime, addUTCTime)
import Data.Traversable
import Data.Universe
import Language.Javascript.JSaddle.Run (syncPoint)
import Language.Javascript.JSaddle.WebSockets
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import qualified Network.HTTP.ReverseProxy as RP
import qualified Network.HTTP.Types as H
import Network.Socket
import qualified Network.URI as NetworkURI
import Network.Wai (Application)
import qualified Network.Wai as W
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WarpTLS
import Network.Wai.Handler.Warp.Internal (settingsHost, settingsPort)
import Network.WebSockets (ConnectionOptions)
import Network.WebSockets.Connection (defaultConnectionOptions)
import qualified Obelisk.Asset.Serve.Snap as Snap
import Obelisk.Backend
import Obelisk.Frontend
import Obelisk.Route.Frontend
import qualified OpenSSL.PEM as PEM
import qualified OpenSSL.RSA as RSA
import qualified OpenSSL.X509 as X509
import qualified OpenSSL.X509.Request as X509Request
import Reflex.Dom.Core
import Snap.Core (Snap)
import System.Environment
import System.IO
import System.Process
import Text.URI (URI)
import qualified Text.URI as URI
import Text.URI.Lens
import Web.Cookie
import Data.GADT.Compare

#if defined(IPROUTE_SUPPORTED)
import qualified System.Which
#endif

run
  :: forall route. (Universe (SomeDomain route), GCompare route)
  => Int -- ^ Port to run the backend
  -> ([Text] -> Snap ()) -- ^ Static asset handler
  -> Backend route -- ^ Backend
  -> IO ()
run port serveStaticAsset backend = do
  prettifyOutput
  publicConfigs <- getPublicConfigs
  let handleBackendErr (e :: IOException) = hPutStrLn stderr $ "backend stopped; make a change to your code to reload - error " <> show e
  --TODO: Use Obelisk.Backend.runBackend; this will require separating the checking and running phases
  case checkAllEncoders $ _backend_routeEncoder backend of
    Left e -> hPutStrLn stderr $ "backend error:\n" <> T.unpack e
    Right (CheckedEncoders mkValidEncoder) -> do
      let routeConfig = getCheckedRouteConfig publicConfigs
          backwardsURI :: Map (Maybe Domain) (SomeDomain route)
          backwardsURI = Map.fromList $ (\(SomeDomain route) -> (uriToDomain $ _backend_obRunBaseRoute backend routeConfig route, SomeDomain route)) <$> universe
          parseDomain :: Domain -> SomeDomain route
          parseDomain d = case Map.lookup (Just d) backwardsURI of
              Nothing -> error $ "parseDomain: couln't find URI: " <> show d
              Just someDomain -> someDomain
      backendTid <- forkIO $ handle handleBackendErr $ withArgs ["--quiet", "--port", show port] $
        _backend_run backend $ \(serveRoute :: forall b f. route (R (FullRoute b f)) -> R b -> Snap ()) ->
          runSnapWithCommandLineArgs $
            getRouteWith parseDomain mkValidEncoder $ \domainPart -> \case
              Identity (r :: R (FullRoute b f)) -> case r of
                FullRoute_Backend backendRoute :/ a -> do
                  liftIO $ putStrLn $ "backendRoute"
                  serveRoute domainPart $ backendRoute :/ a
                FullRoute_Frontend obeliskRoute :/ a ->
                  serveDefaultObeliskApp
                    appRouteToUrl
                    (($ allJsUrl) <$> defaultGhcjsWidgets)
                    serveStaticAsset
                    (_backend_frontend backend domainPart)
                    (_backend_frontendName backend domainPart) -- Not actually used in this case
                    publicConfigs
                    (obeliskRoute :/ a)
                  where
                    appRouteToUrl (k :/ v) = renderObeliskRoute (mkValidEncoder domainPart) (FullRoute_Frontend (ObeliskRoute_App k) :/ v)
                    allJsUrl = renderAllJsPath (mkValidEncoder domainPart)

      let conf = defRunConfig { _runConfig_redirectPort = port }
      runWidget conf publicConfigs backend mkValidEncoder `finally` killThread backendTid

--run
--  :: forall route. (Has C route, GEq route, Universe (SomeDomain route))
--  => Int -- ^ Port to run the backend
--  -> ([Text] -> Snap ()) -- ^ Static asset handler
--  -> Backend route -- ^ Backend
--  -> IO ()
--run port serveStaticAsset backend = do
--  prettifyOutput
--  publicConfigs <- getPublicConfigs
--  let routeConfig = getCheckedRouteConfig publicConfigs
--  let handleBackendErr (e :: IOException) = hPutStrLn stderr $ "backend stopped; make a change to your code to reload - error " <> show e
--  --TODO: Use Obelisk.Backend.runBackend; this will require separating the checking and running phases
--  case checkEncoder $ _backend_routeEncoder backend routeConfig of
--    Left e -> hPutStrLn stderr $ "backend error:\n" <> T.unpack e
--    Right (validFullEncoder :: Encoder Identity Identity (R route) DomainPageName) -> do
--      --let backwardsURI :: Map (Maybe Domain) (SomeDomain route)
--      --    backwardsURI = Map.fromList $ (\(SomeDomain route) -> (uriToDomain $ _backend_baseRoute backend routeConfig route, SomeDomain route)) <$> universe
--      --    parseDomain :: Domain -> SomeDomain route
--      --    parseDomain d = case Map.lookup (Just d) backwardsURI of
--      --        Nothing -> error $ "parseDomain: couln't find URI: " <> show d
--      --        Just someDomain -> someDomain
--      backendTid <- forkIO $ handle handleBackendErr $ withArgs ["--quiet", "--port", show port] $
--        _backend_run backend $ \(serveRoute :: forall b f. route (R (FullRoute b f)) -> R b -> Snap ()) ->
--          runSnapWithCommandLineArgs $
--            getRouteWith validFullEncoder $ \outerRoute -> \case
--              (innerRoute :: R (FullRoute b f)) -> case innerRoute of
--                FullRoute_Backend backendRoute :/ a -> do
--                  liftIO $ putStrLn $ "backendRoute"
--                  serveRoute outerRoute $ backendRoute :/ a
--                FullRoute_Frontend obeliskRoute :/ a ->
--                  serveDefaultObeliskApp
--                    appRouteToUrl
--                    (($ allJsUrl) <$> defaultGhcjsWidgets)
--                    serveStaticAsset
--                    (_backend_frontend backend outerRoute)
--                    publicConfigs
--                    (obeliskRoute :/ a)
--                  where
--                    appRouteToUrl (k :/ v) = renderFullObeliskRoute validFullEncoder $ outerRoute :/ (FullRoute_Frontend (ObeliskRoute_App k) :/ v)
--                    allJsUrl = renderAllJsPath validFullEncoder outerRoute

--      let conf = defRunConfig { _runConfig_redirectPort = port }
--      runWidget conf publicConfigs backend validFullEncoder `finally` killThread backendTid


-- Convenience wrapper to handle path segments for 'Snap.serveAsset'
runServeAsset :: FilePath -> [Text] -> Snap ()
runServeAsset rootPath = Snap.serveAsset "" rootPath . T.unpack . T.intercalate "/"

getConfigRoute :: Map Text ByteString -> Either Text URI
getConfigRoute configs = case Map.lookup "common/route" configs of
    Just r ->
      let stripped = T.strip (T.decodeUtf8 r)
      in case URI.mkURI stripped of
          Just route -> Right route
          Nothing -> Left $ "Couldn't parse route as URI; value read was: " <> T.pack (show stripped)
    Nothing -> Left $ "Couldn't find config file common/route; it should contain the site's canonical root URI" <> T.pack (show $ Map.keys configs)

runWidget
  :: forall route. (Universe (SomeDomain route))
  => RunConfig
  -> Map Text ByteString
  -> Backend route
  -- -> Encoder Identity Identity (R route) DomainPageName
  -> (forall b f. route (R (FullRoute b f)) -> Encoder Identity Identity (R (FullRoute b f)) PageName)
  -> IO ()
runWidget conf configs backend mkValidFullEncoder = do
  let routeConfig = getCheckedRouteConfig configs
  threads <- for universe $ \(SomeDomain baseRoute :: SomeDomain route) -> async $ do
    --let thisEncoder = reverseEncoder validFullEncoder baseRoute
    let thisEncoder = mkValidFullEncoder baseRoute
    let uri' = _backend_obRunBaseRoute backend routeConfig baseRoute
    uri <- either (fail . show) pure $ URI.mkURI $ T.pack $ NetworkURI.uriToString id uri' ""
    let port = fromIntegral $ fromMaybe 80 $ uri ^? uriAuthority . _Right . authPort . _Just
        redirectHost = _runConfig_redirectHost conf
        redirectPort = _runConfig_redirectPort conf
        beforeMainLoop = do
          putStrLn $ "Frontend running on " <> T.unpack (URI.render uri)
        settings = setBeforeMainLoop beforeMainLoop (setPort port (setTimeout 3600 defaultSettings))
        -- Providing TLS here will also incidentally provide it to proxied requests to the backend.
        prepareRunner = case uri ^? uriScheme . _Just . unRText of
          Just "https" -> do
            -- Generate a private key and self-signed certificate for TLS
            privateKey <- RSA.generateRSAKey' 2048 3

            certRequest <- X509Request.newX509Req
            _ <- X509Request.setPublicKey certRequest privateKey
            _ <- X509Request.signX509Req certRequest privateKey Nothing

            cert <- X509.newX509 >>= X509Request.makeX509FromReq certRequest
            _ <- X509.setPublicKey cert privateKey
            now <- getCurrentTime
            _ <- X509.setNotBefore cert $ addUTCTime (-1) now
            _ <- X509.setNotAfter cert $ addUTCTime (365 * 24 * 60 * 60) now
            _ <- X509.signX509 cert privateKey Nothing

            certByteString <- BSUTF8.fromString <$> PEM.writeX509 cert
            privateKeyByteString <- BSUTF8.fromString <$> PEM.writePKCS8PrivateKey privateKey Nothing

            return $ runTLSSocket (tlsSettingsMemory certByteString privateKeyByteString)
          _ -> return runSettingsSocket
    runner <- prepareRunner
    bracket
      (bindPortTCPRetry settings (logPortBindErr port) (_runConfig_retryTimeout conf))
      close
      (\skt -> do
          man <- newManager defaultManagerSettings
          app <- obeliskApp configs defaultConnectionOptions (_backend_frontend backend baseRoute) thisEncoder uri $ fallbackProxy redirectHost redirectPort man
          runner settings skt app)
  traverse_ wait threads `finally` traverse_ cancel threads

requestDomainWai :: W.Request -> Domain
requestDomainWai req = Domain $ "//" <> hostName
  where hostName = maybe "" T.decodeUtf8 $ W.requestHeaderHost req

obeliskApp
  :: forall frontendRoute backendRoute
  .  Map Text ByteString
  -> ConnectionOptions
  -> Frontend (R frontendRoute)
  -> Encoder Identity Identity (R (FullRoute backendRoute frontendRoute)) PageName
  -> URI
  -> Application
  -> IO Application
obeliskApp configs opts frontend validFullEncoder uri backend = do
  let mode = FrontendMode
        { _frontendMode_hydrate = True
        , _frontendMode_adjustRoute = False
        }
      entryPoint = do
        runFrontendWithConfigsAndCurrentRoute mode configs validFullEncoder frontend
        syncPoint
  jsaddlePath <- URI.mkPathPiece "jsaddle"
  let jsaddleUri = BSLC.fromStrict $ URI.renderBs $ uri & uriPath %~ (<>[jsaddlePath])
  Right (jsaddleWarpRouteValidEncoder :: Encoder Identity (Either Text) (R JSaddleWarpRoute) PageName) <- return $ checkEncoder jsaddleWarpRouteEncoder
  jsaddle <- jsaddleWithAppOr opts entryPoint $ \_ sendResponse -> sendResponse $ W.responseLBS H.status500 [("Content-Type", "text/plain")] "obeliskApp: jsaddle got a bad URL"
  return $ \req sendResponse -> case tryDecode validFullEncoder $ byteStringsToPageName (BS.dropWhile (== (fromIntegral $ fromEnum '/')) $ W.rawPathInfo req) (BS.drop 1 $ W.rawQueryString req) of
    Identity r -> case r of
      FullRoute_Frontend (ObeliskRoute_Resource ResourceRoute_JSaddleWarp) :/ jsaddleRoute -> case jsaddleRoute of
        JSaddleWarpRoute_JavaScript :/ () -> sendResponse $ W.responseLBS H.status200 [("Content-Type", "application/javascript")] $ jsaddleJs' (Just jsaddleUri) False
        _ -> flip jsaddle sendResponse $ req
          { W.pathInfo = fst $ encode jsaddleWarpRouteValidEncoder jsaddleRoute
          }
      FullRoute_Frontend (ObeliskRoute_App appRouteComponent) :/ appRouteRest -> do
        let cookies = maybe [] parseCookies $ lookup (fromString "Cookie") (W.requestHeaders req)
            routeToUrl (k :/ v) = renderObeliskRoute validFullEncoder $ FullRoute_Frontend (ObeliskRoute_App k) :/ v
        html <- renderJsaddleFrontend configs cookies routeToUrl (appRouteComponent :/ appRouteRest) frontend
        sendResponse $ W.responseLBS H.status200 [("Content-Type", staticRenderContentType)] $ BSLC.fromStrict html
      _ -> backend req sendResponse

renderJsaddleFrontend
  :: Map Text ByteString
  -> Cookies
  -> (route -> Text)
  -> route
  -> Frontend route
  -> IO ByteString
renderJsaddleFrontend configs cookies urlEnc r f =
  let jsaddleScript = elAttr "script" ("src" =: "/jsaddle/jsaddle.js") blank
      jsaddlePreload = elAttr "link" ("rel" =: "preload" <> "as" =: "script" <> "href" =: "/jsaddle/jsaddle.js") blank
  in renderFrontendHtml configs cookies urlEnc r f jsaddlePreload jsaddleScript

-- | like 'bindPortTCP' but reconnects on exception
bindPortTCPRetry :: Settings
                 -> (IOError -> IO ()) -- ^ Action to run the first time an exception is caught
                 -> Int
                 -> IO Socket
bindPortTCPRetry settings m n = catch (bindPortTCP (settingsPort settings) (settingsHost settings)) $ \(e :: IOError) -> do
  m e
  threadDelay $ 1000000 * n
  bindPortTCPRetry settings (\_ -> pure ()) n

logPortBindErr :: Int -> IOError -> IO ()
logPortBindErr p e = getProcessIdForPort p >>= \case
  Nothing -> putStrLn $ "runWidget: " <> show e
  Just pid -> putStrLn $ unwords [ "Port", show p, "is being used by process ID", show pid <> ".", "Please kill that process or change the port in config/common/route."]

ssPath :: Maybe String
ssPath =
#if defined(IPROUTE_SUPPORTED)
  Just $(System.Which.staticWhich "ss")
#else
  Nothing
#endif

getProcessIdForPort :: Int -> IO (Maybe Int)
getProcessIdForPort port = case ssPath of
  Just ss -> do
    xs <- lines <$> readProcess ss ["-lptn", "sport = " <> show port] mempty
    case uncons xs of
      Just (_, x:_) -> return $ A.maybeResult $ A.parse parseSsPid $ BSC.pack x
      _ -> return Nothing
  _ -> return Nothing

parseSsPid :: A.Parser Int
parseSsPid = do
  _ <- A.count 5 $ A.takeWhile (not . A.isSpace) *> A.skipSpace
  _ <- A.skipWhile (/= ':') >> A.string ":((" >> A.skipWhile (/= ',')
  A.string ",pid=" *> A.decimal

fallbackProxy :: ByteString -> Int -> Manager -> Application
fallbackProxy host port = RP.waiProxyTo handleRequest RP.defaultOnExc
  where handleRequest _req = return $ RP.WPRProxyDest $ RP.ProxyDest host port

data RunConfig = RunConfig
  { _runConfig_port :: Int
  , _runConfig_redirectHost :: ByteString
  , _runConfig_redirectPort :: Int
  , _runConfig_retryTimeout :: Int -- seconds
  }

defRunConfig :: RunConfig
defRunConfig = RunConfig
  { _runConfig_port = 8000
  , _runConfig_redirectHost = "127.0.0.1"
  , _runConfig_redirectPort = 3001
  , _runConfig_retryTimeout = 1
  }
