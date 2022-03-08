-- | Wrapper for the k8s.
--
-- This is a wrapper that provides the interface for running the application
-- in the kubernetes system. This module spawns the server on internal protocol
-- that provides endpoints for starup, liveness and readyness checks as well
-- as optional metrics support.
-- 
-- Restrictions:
--
--   * In order to work propertly the server should be running in the main thread,
--     otherwise we can't guarantee that the server will exit properly. In absence
--     of this guarantee application and k8s will still work, but rollout update
--     procedures may take much longer.
--
--   * User application should be able to teardown on receiving AsyncCancelled or
--      ThreadKilled, it's should be ok, to implement graceful teardown, but it
--      should be bounded by the time.
--     In general applications that are using Warp handles this well automatically.
--
--
-- Here is a part of the pod configuration that can be used with this wrapper.
--
-- @
-- ...
-- spec:
--   containers:
--     - lifecycle:
--         preStop:
--           httpGet:
--            path: /stop
--            port: ${config.port}
--           # Period when after which the pod will be terminated
--           # even if the stop hook has not returned.
--           terminationGracePeriodSeconds: 30
--        # When the service is considered started
--        # if the startup probe will not return success in
--        #  `initialDealySeconds + periodSeconds * failureThreshold` seconds
--        # the service will be restarted
--        startupProbe:
--          httpGet:
--            path: /ready
--            port: ${config.port}
--          failureThreshold: 12
--          initialDelaySeconds: 1
--          periodSeconds: 5
--          successThreshold: 1
--          timeoutSeconds: 2 
--       # When the service is considered alive, if it's not alive it will be
--       # restarted according to it's policy 
--       # initialDealySeconds + periodSeconds * failureThreshold
--       livenessProbe:
--          httpGet:
--            path: /health
--            port: ${config.health}
--          failureThreshold: 2
--          initialDelaySeconds: 1
--          periodSeconds: 10
--          successThreshold: 1
--          timeoutSeconds: 2
--        readinessProbe:
--          httpGet:
--            path: /ready
--            port:${config.port}
--          failureThreshold: 2
--          initialDelaySeconds: 1
--          periodSeconds: 10
--          successThreshold: 1
--          timeoutSeconds: 2
--
-- @
--
-- Examples
module Network.K8s 
  ( withK8sEndpoint
  , Config(..)
    -- * Checks
    -- $k8s-checks
  , K8sChecks(..)
  ) where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Data.Foldable
import Data.Text qualified as T
import Network.HTTP.Types
import Network.Wai as Wai
import Network.Wai.Handler.Warp qualified             as Warp
import Network.Wai.Middleware.Prometheus    as Prometheus

-- | Server configuration
data Config = Config
  { port :: Int 
  , maxTearDownPeriodSeconds :: Int
  } deriving (Show)

-- | Default configuration variables.
defConfig :: Config
defConfig = Config 10120 30

-- $k8s-checks
-- 
-- There can be two types of the health check:
--
--   1. deep check - the check that not only ensures basic startup, but verifies
--        that the services that our service communicates are up and running.
--
--   2. shallow check - the check that provides only the basic tests that application
--        is running.
-- 
-- The deep check is more precise but it increases the chances that interim error
-- will lead to marking services as unavailable and lead to a cascading errors in
-- the end. So it's adviced to use deep checks in the 'startupCheck', but use shallow check
-- for liveness check, as for the readyness check it's up to the user.
--
-- The library authors suggest the following approach.
-- 
--   1. 'startupCheck' returns true after the server is started configs were checked and
--       communication with other services was established. After replying with 'True' once
--       the function always returns 'True'. 
--
--   2. 'readynessCheck' should return 'True' after startup check has passed and after population
--       of the caches, preparing of the internal structures and so on. The function may switch
--       back to 'False' in case if the structures needs repopulation and we can't serve the users.
--       It's important to ensure that all the services in cluster will not switch to not ready
--       state at the same time to avoid cascading failures.
--
--   3. 'livenessCheck' performs shallow check of the service, and returns the state accordingly,
--       generally the livenessCheck should return 'False' only in the case if the server should be
--       restarted.

-- | Callbacks that the wrapper can use in order to understand the state of
-- the application and react accordingly.
data K8sChecks = K8sChecks
  { runReadynessCheck :: IO Bool -- ^ Checks that application can receive requests
  , runLivenessCheck :: IO Bool  -- ^ Checks that application running (should not be restarted)
  }

-- | Application state.
data ApplicationState
  = ApplicationStarting (Async ())
  | ApplicationRunning
  | ApplicationTeardownConfirm (TVar Bool)
  | ApplicationTearingDown
  

-- | Wrap a server that allows controlling business logic server. The server can be
-- communicated by the k8s services and can monitor the application livecycle.
-- 
-- In addition to the callbacks that the server is running it provides some additional
-- logic:
--
--   1. when checking the liveness the code checks if the thread running the server is
--      still alive and returns 'False' if not, not matter what liveness check returns.
--
--   2. when 'stop' action was called, the server starts to return 'False' in readyness
--      check, and once it was asked by the server it sends an Exception to the client
--      code. It ensures that no new requests will be sent to the server.
--
withK8sEndpoint
  :: Config -- ^ Static configuration of the endpoint.
  -> K8sChecks
  -> IO a          -- ^ Initialization procedure
  -> (a -> IO b)   -- ^ User supplied logic, see requirements for the server to work properly.
  -> IO ()
withK8sEndpoint Config{..} K8sChecks{..} startup action = do
  startup_handle <- async startup
  state_box <- atomically $ newTVar $ ApplicationStarting (fmap (const ()) startup_handle)
  withAsync (wait startup_handle >>= \x -> atomically (switchToRunning state_box) >> action x) $ \server -> race_ 
    -- wait while the user application will exit on it's own.
    (wait server) 
    -- run the server
    $ Warp.run port
    $ \req resp -> do
       case Wai.pathInfo req of
         ["started"] -> do
           readTVarIO state_box >>= \case
             ApplicationStarting{} ->
               resp $ responseLBS status400 [(hContentType, "text/plain")] "starting"
             ApplicationRunning{} ->
               resp $ responseLBS status200 [(hContentType, "text/plain")] "ok"
             _ -> 
               resp $ responseLBS status200 [(hContentType, "text/plain")] "tearing down"
         ["ready"] -> do
           readTVarIO state_box >>= \case
             ApplicationStarting{} -> 
               resp $ responseLBS status400 [(hContentType, "text/plain")] "starting"
             ApplicationRunning{} -> do
               isReady   <- runReadynessCheck
               if isReady
               then resp $ responseLBS status200 [(hContentType, "text/plain")] "ok"
               else resp $ responseLBS status400 [(hContentType, "text/plain")] "not running"
             ApplicationTeardownConfirm confirmed -> do
               atomically $ writeTVar confirmed True
               resp $ responseLBS status400 [(hContentType, "text/plain")] "tearing down"
             ApplicationTearingDown{} ->
               resp $ responseLBS status400 [(hContentType, "text/plain")] "tearing down"
         ["health"] -> do
           isAlive <- runLivenessCheck 
           if isAlive
           then resp $ responseLBS status200 [(hContentType, "text/plain")] "ok"
           else resp $ responseLBS status400 [(hContentType, "text/plain")] "starting"
         ["stop"]  -> do
           d <- registerDelay (maxTearDownPeriodSeconds * 1_000_000)
           join $ atomically $ switchToTeardown d state_box
           cancel server
           resp $ responseLBS status200 [(hContentType, "text/plain")] "teardown"
         ["_metrics"] -> metricsApp req resp
         -- If it's any other path then we simply return 404
         _ -> resp $ Wai.responseLBS status404 [(hContentType, "text/plain")] "Not found"
    
-- | Switches the application to the tearing down state.
-- 
-- In case if the application was running it injects the confirmation
-- variable that is switched when the k8s system has seen that the
-- application is not ready.
--
-- Returns an action that once finished tells that the application
-- can be teared down. The action does not wait longer that max
-- timeout period
switchToTeardown :: TVar Bool -> TVar ApplicationState -> STM (IO ())
switchToTeardown timeout state = readTVar state >>= \case
    ApplicationStarting{} -> do
      writeTVar state ApplicationTearingDown
      pure $ pure ()
    ApplicationRunning{} -> do
      confirmed <- newTVar False
      writeTVar state $ ApplicationTeardownConfirm confirmed
      pure $ atomically $ asum
       [ readTVar confirmed >>= check
       , readTVar timeout >>= check
       ]
    ApplicationTeardownConfirm confirmed -> do
      pure $ atomically $ asum
        [ readTVar confirmed >>= check
        , readTVar timeout >>= check
        ]
    ApplicationTearingDown -> 
      pure $ pure ()


-- | Switch the state to the running in case if it was started.
-- Otherwise this is a noop.
switchToRunning :: TVar ApplicationState -> STM ()
switchToRunning state = readTVar state >>= \case
  ApplicationStarting{} -> do
    writeTVar state ApplicationRunning
  ApplicationRunning{} -> pure ()
  ApplicationTeardownConfirm{} -> pure ()
  ApplicationTearingDown -> pure ()
