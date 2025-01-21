-- | 
-- = k8s-wrapper
--
-- The k8s Wrapper is a module designed to provide an interface for running
-- applications in the Kubernetes system. This wrapper spawns the server on an
-- internal protocol, providing endpoints for startup, liveness, and
-- readiness checks, as well as optional metrics support.
--
-- There are some restrictions to be aware of when using this module.
-- First, the **server must be running in the main thread** in order to exit properly.
-- If this guarantee is not met, application and k8s will still function, but rollout
-- update procedures may take much longer.
-- 
-- Second, the user's application must be able to tear down upon receiving
-- `AsyncCancelled` or `ThreadKilled` signals. While it's acceptable to implement
-- graceful teardowns, these should be time-bound. In general, applications that use
-- Warp handles this automatically.
--
-- To use the k8s Wrapper, include the following configuration snippet in your pod:
--
-- == __pod.yaml__
-- @
-- ...
-- spec:
--   metadata:
--     annotations:
--       prometheus.io/port: "9121"
--       prometheus.io/scrape: "true"
--       prometheus.io\/path: "\/_metrics"
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
-- @
--
module Network.K8s.Application
  ( withK8sEndpoint
  , Config(..)
  , defConfig
    -- * Checks
    -- $k8s-checks
  , K8sChecks(..)
  ) where

import Control.Concurrent (killThread, threadDelay, forkIO)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (finally, AsyncException, throwIO, fromException)
import Control.Monad
import Data.Foldable
import Network.HTTP.Types
import Network.Wai as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Middleware.Prometheus as Prometheus

-- | Server configuration.
data Config = Config
  { port :: Int  -- ^ Port where control interface is statred.
  , maxTearDownPeriodSeconds :: Int -- ^ How much time to wait before forceful teardown.
  } deriving (Show)

-- | Default configuration variables.
defConfig :: Config
defConfig = Config 10120 30

-- $k8s-checks
-- 
-- There are two types of health checks that can be used:
--
--  1. __Deep check__ - this verifies not only basic startup but also that the services
--     the application communicates with are up and running. It is more precise, but it increases
--     the risk of marking services as unavailable and causing cascading errors. Therefore,
--     it is recommended to use deep checks for the `startupCheck`, but use shallow checks for the `livenessCheck`.
--     As for the `readinessCheck`, it is up to the user to decide which type of check to use.
--  2. __Shallow check__ - this provides only the basic tests to ensure the application is running.
--
-- The suggested approach for implementing the health checks is as follows:
-- 
--  1. The `startupCheck` should return @True@ after the server is started, configs were checked,
--     and communication with other services was established. Once it has returned @True@, the
--     function should always return @True@.
--  2. The `readinessCheck` should return @True@ after the startup check has passed and after
--     population of the caches, preparing of the internal structures, etc. The function may
--     switch back to @False@ if the structures need repopulation and the application
--     can't serve the users. It's important to ensure that all the services in the cluster will
--     not switch to not ready state at the same time to avoid cascading failures.
--  3. The `livenessCheck` performs a shallow check of the service and returns the state accordingly.
--     Generally, the `livenessCheck` should return @False@ only in the case where the server needs to be restarted.

-- | Callbacks that the wrapper can use in order to understand the state of
-- the application and react accordingly.
data K8sChecks = K8sChecks
  { runReadynessCheck :: IO Bool -- ^ Checks that application can receive requests
  , runLivenessCheck :: IO Bool  -- ^ Checks that application running (should not be restarted)
  , internalLogic :: Maybe Application -- ^ Internal application logic to run
  }

-- | Application state.
data ApplicationState
  = ApplicationStarting (Async ())
  | ApplicationRunning
  | ApplicationTeardownConfirm (TVar Bool)
  | ApplicationTearingDown
  

-- | Wrap a server that allows controlling business logic server.
-- The server can be communicated by the k8s services and can monitor the application livecycle.
--
-- In the application run the following logic:
--
-- @
--    k8s_wrapper_server                  user code
--                                   +----------------+
--        ready=false                | initialization |             
--        started=false              |                |
--        alive=false                +----------------+
--                                          |
--        started=true  <-------------------+
--                                          |
--                                   +---------------+
--                                   | start server  |
--                                   +---------------+
--                                          |
--       ready? ---> check user thread, run callback
--       alive? ---> check user thread, run callback
-- @
--             
-- 
-- The server wrapper also provides additional logic:
--   1. When checking liveness, the code checks if the thread running the server is still
--      alive and returns @False@ if it is not, regardless of what liveness check returns.
--   2. When the `stop` action is called, the server starts to return @False@ in the readiness check.
--      Once it is asked by the server, it sends an Exception to the client code.
--      This ensures that no new requests will be sent to the server.
--
-- In case of an asynchronous exception, we expect that we want to terminate the program.
-- Thus, we want to ensure a similar set of actions as a call to the @/stop@ hook:
--
--   1.  Put the application in the tearing down state.
--   2.  Start replying with @ready=False@ replies.
--   3.  Once we replied with @ready=false@ at least once (or after a timeout), we trigger server stop.
--      In this place, we expect the server to stop accepting new connections and exit once all
--      current connections will be processed. This is the responsibility of the function provided by the user,
--      but servers like Warp already handle that properly.
--
-- In case of an exception in the initialization function, it will be rethrown, and the function will exit with the same exception.
-- The k8s endpoint will be torn down.
--
-- In case if the user code exists with an exception, it will be rethrown. Otherwise, the code exits properly.
withK8sEndpoint
  :: Config      -- ^ Static configuration of the endpoint.
  -> K8sChecks   -- ^ K8s hooks
  -> IO a        -- ^ Initialization procedure
  -> (a -> IO b) -- ^ User supplied logic, see requirements for the server to work properly.
  -> IO ()
withK8sEndpoint Config{..} k8s startup action = do
  startup_handle <- async startup
  state_box <- atomically $ newTVar $ ApplicationStarting (fmap (const ()) startup_handle)
  -- We start the server in the background, this is done synchronously
  -- with running initialization procedure.
  withAsync (do
       x <- wait startup_handle
       atomically (switchToRunning state_box)
       action x) $ \server -> do
    k8s_server <- async $ runK8sServiceEndpoint port maxTearDownPeriodSeconds k8s state_box server
    (do result <- atomically $ asum
          [ fmap void $ waitCatchSTM server
          , readTVar state_box >>= \case
              ApplicationTearingDown -> pure $ Right ()
              _ -> retry
          ]
        case result of
          Left se
            | Just (_ :: AsyncCancelled) <- fromException se -> pure ()
            | Just (_ :: AsyncException) <- fromException se -> pure ()
            | otherwise -> throwIO se
          Right{} -> pure ()
        ) `finally`
            (let half_interval = maxTearDownPeriodSeconds * 1_000_000 `div` 2
             in race_ (threadDelay half_interval) (cancel server))
          `finally`
            (forkIO (cancel k8s_server))

-- | Run server with k8s endpoint.
--
-- This endpoint provides k8s hooks:
--   1. start
--   2. liveness
--   3. readyness
--   4. pre_stop handler
-- 
-- All other endpoints returns 404.
runK8sServiceEndpoint
  :: Int -- ^ Port
  -> Int -- ^ Shutdown interval
  -> K8sChecks -- ^ K8s hooks
  -> TVar ApplicationState -- ^ Projection of the application state
  -> Async void -- ^ Handle of the running user code
  -> IO ()
runK8sServiceEndpoint port teardown_time_seconds K8sChecks{..} state_box server = Warp.run port $ \req resp -> do
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
          then resp $ responseLBS status200 [(hContentType, "text/plain")] "running"
          else resp $ responseLBS status400 [(hContentType, "text/plain")] "not running"
        ApplicationTeardownConfirm confirmed -> do
          atomically $ writeTVar confirmed True
          resp $ responseLBS status400 [(hContentType, "text/plain")] "tearing down"
        ApplicationTearingDown{} ->
          resp $ responseLBS status400 [(hContentType, "text/plain")] "tearing down"
    ["health"] -> do
      readTVarIO state_box >>= \case
        ApplicationStarting{} -> 
          resp $ responseLBS status400 [(hContentType, "text/plain")] "starting"
        _ -> do
          isAlive <- runLivenessCheck 
          -- TODO: is thread ok?
          if isAlive
          then resp $ responseLBS status200 [(hContentType, "text/plain")] "running"
          else resp $ responseLBS status400 [(hContentType, "text/plain")] "unhealthy"
    ["stop"]  -> do
      _ <- async $ do
        d <- registerDelay (teardown_time_seconds * 1_000_000)
        join $ atomically $ switchToTeardown d state_box
        -- this is interruptible, and waits until user thread will receive an
        -- exception, but does not wait for the tearing down.
        killThread $ asyncThreadId server
      resp $ responseLBS status200 [(hContentType, "text/plain")] "tearing down"
    ["_metrics"] -> metricsApp req resp
    _ -> case internalLogic of
      -- If it's any other path then we simply return 404
      Nothing -> resp $ Wai.responseLBS status404 [(hContentType, "text/plain")] "Not found"
      -- If internal logic set - run it
      Just application -> application req resp
    
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
    ApplicationStarting init_thread -> do
      writeTVar state ApplicationTearingDown
      pure $ cancel init_thread 
    ApplicationRunning{} -> do
      confirmed <- newTVar False
      writeTVar state $ ApplicationTeardownConfirm confirmed
      pure $ do
        atomically $ asum
         [ readTVar confirmed >>= check
         , readTVar timeout >>= check
         ]
        atomically $ writeTVar state ApplicationTearingDown
    ApplicationTeardownConfirm confirmed -> do
      pure $ do
        atomically $ asum
          [ readTVar confirmed >>= check
          , readTVar timeout >>= check
          ]
        atomically $ writeTVar state ApplicationTearingDown
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
