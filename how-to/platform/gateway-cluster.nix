# how-to-platform-gateway: expose an application through Gateway API.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: the gateway dependency makes kix.expose render an HTTPRoute.
# gateway-api installs the Gateway API CRDs, envoy-gateway-controller
# installs the Envoy Gateway controller, and envoy-gateway adds a Gateway on
# it. The kind flavour has no load balancer, so the proxy Service is a
# NodePort.

{ kix, packages, ... }:

let
  exposureApp = import ./exposure-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-gateway";

  modules = [
    kix.flavors.kind
    {
      # region:gatewayApiInstance
      instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;
      # endregion:gatewayApiInstance

      # region:gatewayControllerInstance
      instances.gateway-system.envoy-gateway-controller.package =
        packages.experimental.envoy-gateway-controller;
      # endregion:gatewayControllerInstance

      # region:gatewayInstance
      instances.gateway-system.gateway = {
        package = packages.experimental.envoy-gateway;
        config.listeners = [
          {
            name = "http";
            port = 80;
            protocol = "HTTP";
            allowedRoutes.namespaces.from = "All";
          }
        ];
      };
      # endregion:gatewayInstance

      # region:gatewayApplicationInstance
      instances.gateway-example.web = {
        package = exposureApp;
        config.ingress.host = "web.example.test";
      };
      # endregion:gatewayApplicationInstance
    }
  ];
}
