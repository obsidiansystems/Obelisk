{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Obelisk.Backend
  ( Backend (..)
  , BackendConfig (..)
  , defaultBackendConfig
  , StaticAssets (..)
  , defaultStaticAssets
  -- * Running a backend
  , runBackend
  , runBackendWith
  -- * Configuration of backend
  , GhcjsWidgets(..)
  , GhcjsWasmAssets(..)
  , defaultGhcjsWidgets
  -- * all.js script loading functions
  , deferredGhcjsScript
  , delayedGhcjsScript
  -- * all.js preload functions
  , preloadGhcjs
  , renderAllJsPath
  -- * Re-exports
  , Default (def)
  , getPageName
  , getRouteWith
  , runSnapWithCommandLineArgs
  , runSnapWithConfig
  , serveDefaultObeliskApp
  , prettifyOutput
  , staticRenderContentType
  , getPublicConfigs
  ) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Fail (MonadFail)
import Control.Lens (view, _1, _2, _3)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC8
import Data.Default (Default (..))
import Data.Dependent.Sum
import Data.Functor.Identity
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Network.URI (escapeURIString, isUnescapedInURIComponent, isUnescapedInURI)
import Obelisk.Asset.Serve.Snap (serveAsset, getAssetPath)
import qualified Obelisk.ExecutableConfig.Lookup as Lookup
import Obelisk.Frontend
import Obelisk.Route
import Obelisk.Snap.Extras (doNotCache, serveFileIfExistsAs)
import Reflex.Dom
import Snap (MonadSnap, Snap, commandLineConfig, defaultConfig, getsRequest, httpServe, modifyResponse
            , rqPathInfo, rqQueryString, setContentType, writeBS, writeText
            , rqCookies, Cookie(..) , setHeader)
import Snap.Internal.Http.Server.Config (Config (accessLog, errorLog), ConfigLog (ConfigIoLog))
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)

data Backend backendRoute frontendRoute = Backend
  { _backend_routeEncoder :: Encoder (Either Text) Identity (R (FullRoute backendRoute frontendRoute)) PageName
  , _backend_run :: ((R backendRoute -> Snap ()) -> IO ()) -> IO ()
  } deriving (Generic)

data BackendConfig frontendRoute = BackendConfig
  { _backendConfig_runSnap :: !(Snap () -> IO ()) -- ^ Function to run the snap server
  , _backendConfig_staticAssets :: !StaticAssets -- ^ Static assets
  , _backendConfig_ghcjsAssets :: !StaticAssets -- ^ Frontend ghcjs (and wasm) assets
  , _backendConfig_ghcjsWidgets :: !(GhcjsWidgets (GhcjsWasmAssets -> FrontendWidgetT (R frontendRoute) ()))
    -- ^ Given the URL of all.js and wasm files, return the widgets which are responsible for
    -- loading the script.
  } deriving (Generic)

-- | The static assets provided must contain a compiled GHCJS app that corresponds exactly to the Frontend provided
data GhcjsApp route = GhcjsApp
  { _ghcjsApp_compiled :: !StaticAssets
  , _ghcjsApp_value :: !(Frontend route)
  } deriving (Generic)

-- | Widgets used to load all.js on the frontend
data GhcjsWidgets a = GhcjsWidgets
  { _ghcjsWidgets_preload :: a
  -- ^ A preload widget, placed in the document head
  , _ghcjsWidgets_script :: a
  -- ^ A script widget, placed in the document body
  } deriving (Functor, Generic)

data GhcjsWasmAssets = GhcjsWasmAssets
  { _ghcjsWasmAssets_allJs :: Text
  -- ^ URL (could be relative) of "all.js"
  , _ghcjsWasmAssets_wasm :: Maybe (Text, WasmAssets)
  -- ^ (Optional) root URL (could be relative) of wasm assets along with
  -- the record of wasm assets.
  -- If this is Nothing, then it means wasm is disabled.
  }

-- | Files needed for wasm, the JS files are from the webabi
data WasmAssets = WasmAssets
  { _wasmAssets_jsaddleJs :: Text
  , _wasmAssets_interfaceJs :: Text
  , _wasmAssets_runnerJs :: Text
  , _wasmAssets_wasmFile :: Text
  }

defaultWasmAssets :: WasmAssets
defaultWasmAssets = WasmAssets
  { _wasmAssets_jsaddleJs = "jsaddle_core.js"
  , _wasmAssets_interfaceJs = "jsaddle_mainthread_interface.js"
  , _wasmAssets_runnerJs = "mainthread_runner.js"
  , _wasmAssets_wasmFile = "frontend.wasm"
  }

-- | Given the URL of all.js, return the widgets which are responsible for
-- loading the script. Defaults to 'preloadGhcjs' and 'deferredGhcjsScript'.
defaultGhcjsWidgets :: GhcjsWidgets (GhcjsWasmAssets -> FrontendWidgetT r ())
defaultGhcjsWidgets = GhcjsWidgets
  { _ghcjsWidgets_preload = preloadGhcjs
  , _ghcjsWidgets_script = deferredGhcjsScript
  }

-- | Serve a frontend, which must be the same frontend that Obelisk has built and placed in the default location
--TODO: The frontend should be provided together with the asset paths so that this isn't so easily breakable; that will probably make this function obsolete
serveDefaultObeliskApp
  :: (MonadSnap m, HasCookies m, MonadFail m)
  => (R appRoute -> Text)
  -> GhcjsWidgets (FrontendWidgetT (R appRoute) ())
  -> ([Text] -> m ())
  -> Frontend (R appRoute)
  -> Map Text ByteString
  -> R (ObeliskRoute appRoute)
  -> m ()
serveDefaultObeliskApp urlEnc ghcjsWidgets serveStaticAsset frontend =
  serveObeliskApp urlEnc ghcjsWidgets serveStaticAsset frontendApp
  where frontendApp = GhcjsApp
          { _ghcjsApp_compiled = defaultFrontendGhcjsAssets
          , _ghcjsApp_value = frontend
          }

prettifyOutput :: IO ()
prettifyOutput = do
  -- Make output more legible by decreasing the likelihood of output from
  -- multiple threads being interleaved
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

defaultStaticAssets :: StaticAssets
defaultStaticAssets = StaticAssets
  { _staticAssets_processed = "static.assets"
  , _staticAssets_unprocessed = "static"
  }

-- This has both ghcjs and wasm assets.
-- The 'unprocessed' is a fallback path, and in case of wasm is invalid (does not contain wasm files)
-- For the standard obelisk deployment the unprocessed path would not be used.
defaultFrontendGhcjsAssets :: StaticAssets
defaultFrontendGhcjsAssets = StaticAssets
  { _staticAssets_processed = "frontend.jsexe.assets"
  , _staticAssets_unprocessed = "frontend.jsexe"
  }

runSnapWithConfig :: MonadIO m => Config Snap a -> Snap () -> m ()
runSnapWithConfig conf a = do
  let httpConf = conf
        { accessLog = Just $ ConfigIoLog BSC8.putStrLn
        , errorLog = Just $ ConfigIoLog BSC8.putStrLn
        }
  -- Start the web server
  liftIO $ httpServe httpConf a

-- Get the web server configuration from the command line
runSnapWithCommandLineArgs :: MonadIO m => Snap () -> m ()
runSnapWithCommandLineArgs s = liftIO (commandLineConfig defaultConfig) >>= \c ->
  runSnapWithConfig c s

getPageName :: (MonadSnap m) => m PageName
getPageName = do
  p <- getsRequest rqPathInfo
  q <- getsRequest rqQueryString
  return $ byteStringsToPageName p q

getRouteWith :: (MonadSnap m) => Encoder Identity parse route PageName -> m (parse route)
getRouteWith e = do
  pageName <- getPageName
  return $ tryDecode e pageName

renderAllJsPath :: Encoder Identity Identity (R (FullRoute a b)) PageName -> Text
renderAllJsPath validFullEncoder =
  renderObeliskRoute validFullEncoder $ FullRoute_Frontend (ObeliskRoute_Resource ResourceRoute_Ghcjs) :/ ["all.js"]

renderWasmPathRoot :: Encoder Identity Identity (R (FullRoute a b)) PageName -> Text
renderWasmPathRoot validFullEncoder =
  renderObeliskRoute validFullEncoder $ FullRoute_Frontend (ObeliskRoute_Resource ResourceRoute_Ghcjs) :/ []

serveObeliskApp
  :: (MonadSnap m, HasCookies m, MonadFail m)
  => (R appRoute -> Text)
  -> GhcjsWidgets (FrontendWidgetT (R appRoute) ())
  -> ([Text] -> m ())
  -> GhcjsApp (R appRoute)
  -> Map Text ByteString
  -> R (ObeliskRoute appRoute)
  -> m ()
serveObeliskApp urlEnc ghcjsWidgets serveStaticAsset frontendApp config = \case
  ObeliskRoute_App appRouteComponent :=> Identity appRouteRest -> serveGhcjsApp urlEnc ghcjsWidgets frontendApp config $ GhcjsAppRoute_App appRouteComponent :/ appRouteRest
  ObeliskRoute_Resource resComponent :=> Identity resRest -> case resComponent :=> Identity resRest of
    ResourceRoute_Static :=> Identity pathSegments -> serveStaticAsset pathSegments
    ResourceRoute_Ghcjs :=> Identity pathSegments -> serveGhcjsApp urlEnc ghcjsWidgets frontendApp config $ GhcjsAppRoute_Resource :/ pathSegments
    ResourceRoute_JSaddleWarp :=> Identity _ -> do
      let msg = "Error: Obelisk.Backend received jsaddle request"
      liftIO $ putStrLn $ T.unpack msg
      writeText msg
    ResourceRoute_Version :=> Identity () -> doNotCache >> serveFileIfExistsAs "text/plain" "version"

serveStaticAssets :: (MonadSnap m, MonadFail m) => StaticAssets -> [Text] -> m ()
serveStaticAssets assets pathSegments = serveAsset (_staticAssets_processed assets) (_staticAssets_unprocessed assets) $ T.unpack $ T.intercalate "/" pathSegments

data StaticAssets = StaticAssets
  { _staticAssets_processed :: !FilePath
  , _staticAssets_unprocessed :: !FilePath
  }
  deriving (Show, Read, Eq, Ord)

data GhcjsAppRoute :: (* -> *) -> * -> * where
  GhcjsAppRoute_App :: appRouteComponent a -> GhcjsAppRoute appRouteComponent a
  GhcjsAppRoute_Resource :: GhcjsAppRoute appRouteComponent [Text]

staticRenderContentType :: ByteString
staticRenderContentType = "text/html; charset=utf-8"

--TODO: Don't assume we're being served at "/"
serveGhcjsApp
  :: (MonadSnap m, HasCookies m, MonadFail m)
  => (R appRouteComponent -> Text)
  -> GhcjsWidgets (FrontendWidgetT (R appRouteComponent) ())
  -> GhcjsApp (R appRouteComponent)
  -> Map Text ByteString
  -> R (GhcjsAppRoute appRouteComponent)
  -> m ()
serveGhcjsApp urlEnc ghcjsWidgets app config = \case
  GhcjsAppRoute_App appRouteComponent :=> Identity appRouteRest -> do
    modifyResponse $ setContentType staticRenderContentType
    modifyResponse $ setHeader "Cache-Control" "no-store private"
    writeBS <=< renderGhcjsFrontend urlEnc ghcjsWidgets (appRouteComponent :/ appRouteRest) config $ _ghcjsApp_value app
  GhcjsAppRoute_Resource :=> Identity pathSegments -> serveStaticAssets (_ghcjsApp_compiled app) pathSegments

-- | Default obelisk backend configuration.
defaultBackendConfig :: BackendConfig frontendRoute
defaultBackendConfig = BackendConfig runSnapWithCommandLineArgs defaultStaticAssets defaultFrontendGhcjsAssets defaultGhcjsWidgets

-- | Run an obelisk backend with the default configuration.
runBackend :: Backend backendRoute frontendRoute -> Frontend (R frontendRoute) -> IO ()
runBackend = runBackendWith defaultBackendConfig

-- | Run an obelisk backend with the given configuration.
runBackendWith
  :: BackendConfig frontendRoute
  -> Backend backendRoute frontendRoute
  -> Frontend (R frontendRoute)
  -> IO ()
runBackendWith (BackendConfig runSnap staticAssets ghcjsAssets ghcjsWidgets) backend frontend = case checkEncoder $ _backend_routeEncoder backend of
  Left e -> fail $ "backend error:\n" <> T.unpack e
  Right validFullEncoder -> do
    publicConfigs <- getPublicConfigs
    enableWasm <- checkWasmFile
    _backend_run backend $ \serveRoute ->
      runSnap $
        getRouteWith validFullEncoder >>= \case
          Identity r -> case r of
            FullRoute_Backend backendRoute :/ a -> serveRoute $ backendRoute :/ a
            FullRoute_Frontend obeliskRoute :/ a ->
              serveObeliskApp routeToUrl widgets (serveStaticAssets staticAssets) frontendApp publicConfigs $
                obeliskRoute :/ a
              where
                routeToUrl (k :/ v) = renderObeliskRoute validFullEncoder $ FullRoute_Frontend (ObeliskRoute_App k) :/ v
                allJsUrl = renderAllJsPath validFullEncoder
                mWasmAssets = if enableWasm
                  then Just (renderWasmPathRoot validFullEncoder, defaultWasmAssets)
                  else Nothing
                widgets = ($ GhcjsWasmAssets allJsUrl mWasmAssets) <$> ghcjsWidgets
                frontendApp = GhcjsApp
                  { _ghcjsApp_compiled = ghcjsAssets
                  , _ghcjsApp_value = frontend
                  }
  where
    checkWasmFile = do
      let base = _staticAssets_processed ghcjsAssets
      (isJust <$>) $ getAssetPath base $ T.unpack $ _wasmAssets_wasmFile defaultWasmAssets

renderGhcjsFrontend
  :: (MonadSnap m, HasCookies m)
  => (route -> Text)
  -> GhcjsWidgets (FrontendWidgetT route ())
  -> route
  -> Map Text ByteString
  -> Frontend route
  -> m ByteString
renderGhcjsFrontend urlEnc ghcjsWidgets route configs f = do
  cookies <- askCookies
  renderFrontendHtml configs cookies urlEnc route f (_ghcjsWidgets_preload ghcjsWidgets) (_ghcjsWidgets_script ghcjsWidgets)

-- | Preload all.js in a link tag.
-- This is the default preload method.
preloadGhcjs :: GhcjsWasmAssets -> FrontendWidgetT r ()
preloadGhcjs (GhcjsWasmAssets allJsUrl mWasm) = case mWasm of
  Nothing -> elAttr "link" ("rel" =: "preload" <> "as" =: "script" <> "href" =: (escapeURI allJsUrl)) blank
  Just wasmAssets -> scriptTag $ view _1 (wasmScripts allJsUrl wasmAssets)

-- | Load the script from the given URL in a deferred script tag.
-- This is the default method.
deferredGhcjsScript :: GhcjsWasmAssets -> FrontendWidgetT r ()
deferredGhcjsScript (GhcjsWasmAssets allJsUrl mWasm) = case mWasm of
  Nothing -> elAttr "script" ("type" =: "text/javascript" <> "src" =: (escapeURI allJsUrl) <> "defer" =: "defer") blank
  Just wasmAssets -> scriptTag $ view _2 (wasmScripts allJsUrl wasmAssets)

scriptTag :: DomBuilder t m => Text -> m ()
scriptTag t = elAttr "script" ("type" =: "text/javascript") $ text t

escapeURI :: Text -> Text
escapeURI = T.pack . escapeURIString isUnescapedInURI . T.unpack

escapeURIComponent :: Text -> Text
escapeURIComponent = T.pack . escapeURIString isUnescapedInURIComponent . T.unpack

wasmScripts
  :: Text
  -- ^ URL (could be relative) of "all.js"
  -> (Text, WasmAssets)
  -- ^ Root URL (could be relative) of wasm assets along with
  -- the record of wasm assets.
  -> (Text, Text, (Int -> Text))
  -- ^ (preload script, deferred run script, delayed run script (Int input is the delay))
wasmScripts allJsUrl' (wasmRoot, wAssets) = (preloadScript, runJsScript, delayedJsScript)
  where
    wrapName f = "'" <> escapeURI wasmRoot <> "/" <> escapeURIComponent (f wAssets) <> "'"
    jsaddleJs = wrapName _wasmAssets_jsaddleJs
    interfaceJs = wrapName _wasmAssets_interfaceJs
    runnerJs = wrapName _wasmAssets_runnerJs
    wasmUrl = wrapName _wasmAssets_wasmFile
    allJsUrl = "'" <> escapeURI allJsUrl' <> "'"

    preloadScript =
      "add_preload_tag = function (docSrc) {\
        \var link_tag = document.createElement('link');\
        \link_tag.rel = 'preload';\
        \link_tag.as = 'script';\
        \link_tag.href = docSrc;\
        \document.head.appendChild(link_tag);\
      \};\
      \if (typeof(WebAssembly) === 'undefined') {\
        \add_preload_tag(" <> allJsUrl <> ");\
      \} else {\
        \add_preload_tag(" <> wasmUrl <> ");\
        \add_preload_tag(" <> jsaddleJs <> ");\
        \add_preload_tag(" <> interfaceJs <> ");\
        \add_preload_tag(" <> runnerJs <> ");\
      \}"

    -- The 'WASM_URL_FOR_MAINTHREAD_RUNNER_JS' variable is needed here because
    -- the export API is not working in the webabi ts code.
    -- This variable is read by the runnerJs.
    runJsScript =
      "add_deferload_tag = function (docSrc) {\
        \var tag = document.createElement('script');\
        \tag.type = 'text/javascript';\
        \tag.src = docSrc;\
        \tag.setAttribute('defer', 'defer');\
        \document.body.appendChild(tag);\
      \};\
      \if (typeof(WebAssembly) === 'undefined') {\
        \add_deferload_tag(" <> allJsUrl <> ");\
      \} else {\
        \var WASM_URL_FOR_MAINTHREAD_RUNNER_JS = " <> wasmUrl <> ";\
        \add_deferload_tag(" <> jsaddleJs <> ");\
        \add_deferload_tag(" <> interfaceJs <> ");\
        \add_deferload_tag(" <> runnerJs <> ");\
      \}"

    delayedJsScript n =
      "var WASM_URL_FOR_MAINTHREAD_RUNNER_JS = " <> wasmUrl <> ";\
      \setTimeout(function() {\
        \add_load_tag = function (docSrc) {\
          \var tag = document.createElement('script');\
          \tag.type = 'text/javascript';\
          \tag.src = docSrc;\
          \document.body.appendChild(tag);\
        \};\
        \if (typeof(WebAssembly) === 'undefined') {\
          \add_load_tag(" <> allJsUrl <> ");\
        \} else {\
          \add_load_tag(" <> jsaddleJs <> ");\
          \add_load_tag(" <> interfaceJs <> ");\
          \add_load_tag(" <> runnerJs <> ");\
        \}\
      \}, " <> T.pack (show n) <> ");"

-- | An all.js script which is loaded after waiting for some time to pass. This
-- is useful to ensure any CSS animations on the page can play smoothly before
-- blocking the UI thread by running all.js.
delayedGhcjsScript
  :: Int -- ^ The number of milliseconds to delay loading by
  -> GhcjsWasmAssets
  -> FrontendWidgetT r ()
delayedGhcjsScript n (GhcjsWasmAssets allJsUrl mWasm) = scriptTag scriptToRun
  where
    scriptToRun = case mWasm of
      Nothing -> T.unlines
        [ "setTimeout(function() {"
        , "  var all_js_script = document.createElement('script');"
        , "  all_js_script.type = 'text/javascript';"
        , "  all_js_script.src = '" <> escapeURI allJsUrl <> "';"
        , "  document.body.appendChild(all_js_script);"
        , "}, " <> T.pack (show n) <> ");"
        ]
      Just wasmAssets -> (view _3 (wasmScripts allJsUrl wasmAssets)) n

instance HasCookies Snap where
  askCookies = map (\c -> (cookieName c, cookieValue c)) <$> getsRequest rqCookies

-- | Get configs from the canonical "public" locations (i.e., locations that obelisk expects to make available
-- to frontend applications, and hence visible to end users).
getPublicConfigs :: IO (Map Text ByteString)
getPublicConfigs = Map.filterWithKey (\k _ -> isMemberOf k ["common", "frontend"]) <$> Lookup.getConfigs
  where
    isMemberOf k = any (`T.isPrefixOf` k)
