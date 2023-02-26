k8s-wrapper is a [wai](https://hackage.haskell.org/package/wai) application that is designed to wrap your service running in a k8s
environment and provide the additional functionality needed for a fully-featured application
to operate. It accomplishes it in several ways:

  1. **Health and liveness Endpoints** — the feature provides information on the current state
     of the application, allowing k8s to control execution, restart application, manage rollouts
     and route traffic
  2. **Startup and Teardown Control** — the application's statup and teardown processes are managed
     by `k8s-wrapper`, ensuring that your service operates smoothly
  3. **Graceful Shutdown Endpoint** — This feature enables graceful shutdown of your service.
  4. **Metrics Enpoint** — Metrics are exposed on a dedicated endpoint, allowing for easy monitoring
     of your application's performance

By utilizing k8s-wrapper, you can simplify the management of your service and ensure that it runs
reliably in a k8s environment

# Get Started

In order to use k8s application you should do:

1. All k8s-wrapper to the list of dependencies in the cabal file:

```cabal
executable mega-service
  build-depends: base >= 4.4,
    k8s-wrapper,
    ...
  ...
```

2. In the main file use:

```haskell
import Network.K8s.Application as K8s

main :: IO ()
main = do
  let runReadynessCheck = do 
        -- In this function we check if the traffic can be routed to the
        -- application. If this function returns False traffic will not
        -- be routed to the application.
        pure True
  let runLivenessCheck = do
        -- Check if the application is in a workable state. If returns `False`
        -- then k8s based on it's rules may restart the application.
        pure True
  let initializeServer = do
        -- This function is used to initialize the service, for example
        -- setup connection to the databases, check config files, register metrics
        _ <- register ghcMetrics
        -- While this function is executing k8s-wrapper replies the
        -- status on it's interface.
 
        -- This function returns created resources that may be needed for the
        -- application.
        pure ()
  withK8sEndpoint
    K8s.defConfig -- Default configuration
    K8sChecks{ runReadynessCheck, runLivenessCheck }
    initializeServer
    (\resources -> Warp.run application_port (yourApp resources)) 
```

After settings k8s-wrapper will start the interface on the port 10120 (can be redefinen in the config),
that provides endpoints:

   - **/started** — provides information if application is started
   - **/ready** — provides information if application can accept the traffic
   - **/health** — provides information if application is healthy
   - **/stop** — preStop hook — requests application teardown
   - `/_metrics` - output metrics for the application
  
For the machine readable format you can check `spec.yaml` file provided with the package
that provides openapi v3 definition of the endpoints.

