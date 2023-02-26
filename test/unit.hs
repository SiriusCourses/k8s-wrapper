{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.IORef
import Test.Tasty
import Test.Tasty.HUnit
import Network.K8s.Application qualified as K8s
import Network.HTTP.Client
import Network.HTTP.Types

main :: IO ()
main = defaultMain tests

isAlive, isReady, isStarted :: Manager -> IO Bool
isAlive manager =
  let req = "http://127.0.0.1:10120/health"
  in httpNoBody req manager <&> (==200) . statusCode . responseStatus   
isReady manager = 
  let req = "http://127.0.0.1:10120/ready"
  in httpNoBody req manager <&> (==200) . statusCode . responseStatus   
isStarted manager =
  let req = "http://127.0.0.1:10120/started"
  in httpNoBody req manager <&> (==200) . statusCode . responseStatus   
stopIt :: Manager -> IO ()
stopIt manager =
  let req = "http://127.0.0.1:10120/stop"
  in void $ httpNoBody req manager

tests :: TestTree
tests = testGroup "unit"
  [ testGroup "startup"
     [ testCaseSteps "Normal startup" $ \step -> do
         manager <- newManager defaultManagerSettings
         step "Preparing.."
         lock <- newEmptyMVar
         finished <- newEmptyMVar
         closed <- newEmptyMVar
         ready_var <- newIORef True
         alive_var <- newIORef True
         k8s <- async $ K8s.withK8sEndpoint
                  K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
                  K8s.K8sChecks
                    { K8s.runReadynessCheck = readIORef ready_var
                    , K8s.runLivenessCheck = readIORef alive_var
                    }
                  (takeMVar lock)
                  (\x -> putMVar finished x >> takeMVar closed)
         assertBool "appication should not be started" . not =<< isStarted manager
         assertBool "appication should not be ready" . not =<< isReady manager
         assertBool "appication should not be alive" . not =<< isAlive manager
         step "initialization has finished"
         writeIORef ready_var False
         writeIORef alive_var False
         putMVar lock () >> yield
         assertBool "appication should be started" =<< isStarted manager
         assertBool "appication should not be ready" . not =<< isReady manager
         assertBool "appication should not be alive" . not =<< isAlive manager
         step "application is alive now"
         writeIORef alive_var True
         assertBool "appication should be started" =<< isStarted manager
         assertBool "appication should not be ready" . not =<< isReady manager
         assertBool "appication should be alive" =<< isAlive manager
         writeIORef ready_var True
         step "application is ready now"
         assertBool "appication should be started" =<< isStarted manager
         assertBool "appication should be ready" =<< isReady manager
         assertBool "appication should be alive" =<< isAlive manager
         step "teardown"
         cancel k8s
     , testCase "Exception on startup" $ do
       e <- try $ K8s.withK8sEndpoint
         K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
         (K8s.K8sChecks (pure True) (pure True))
         (throwIO (userError "foo") :: IO ())
         (pure)
       assertEqual "Should be exception" (Left (userError "foo")) e
     , testCase "Exits on application exit" $ do
        K8s.withK8sEndpoint
          K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
          (K8s.K8sChecks (pure True) (pure True)) (pure ())
          pure
     ] 
  , testGroup "teardown"
     [ testCaseSteps "Kills application after /stop and /ready" $ \step -> do
         manager <- newManager defaultManagerSettings
         lock <- newEmptyMVar
         received_exception <- newIORef False
         x <- async $ K8s.withK8sEndpoint
             K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
             (K8s.K8sChecks (pure True) (pure True))
             (pure ())
             (\() -> do
                takeMVar lock `finally` (writeIORef received_exception True))
         step "Stopping the application"
         stopIt manager
         replicateM_ 100 yield -- Hack :(
         step "Check that it's still running"
         assertBool "should not receive exception" . not =<< readIORef received_exception
         step "Check ready"
         assertBool "appication should not be ready" . not =<< isReady manager
         step "Check that application is closing"
         assertBool "should receive exception" =<< readIORef received_exception
         wait x
         putMVar lock ()
     , testCaseSteps "Kills application after /stop and timeout" $ \step -> do
         manager <- newManager defaultManagerSettings
         lock <- newEmptyMVar
         received_exception <- newIORef False
         x <- async $ K8s.withK8sEndpoint
             K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
             (K8s.K8sChecks (pure True) (pure True))
             (pure ())
             (\() -> do
                takeMVar lock `finally` (writeIORef received_exception True))
         step "Stopping the application"
         stopIt manager
         replicateM_ 100 yield -- Hack :(
         step "Check that it's still running"
         assertBool "should not receive exception" . not =<< readIORef received_exception
         wait x
         putMVar lock ()
     , testCase "Exits if application is terminating for too long" $ do
         manager <- newManager defaultManagerSettings
         lock <- newEmptyMVar
         x <- async $ K8s.withK8sEndpoint
             K8s.defConfig{K8s.maxTearDownPeriodSeconds=1}
             (K8s.K8sChecks (pure True) (pure True))
             (pure ())
             (\() -> do
                takeMVar lock `finally` (takeMVar lock))
         stopIt manager
         wait x
         putMVar lock ()
     ]
  ]
