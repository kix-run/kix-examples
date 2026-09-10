# how-to-platform-gateway: expose an application through Gateway API.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: the gateway dependency makes kix.expose render an HTTPRoute.

{ kix, packages, ... }:

let
  exposureApp = import ./exposure-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-gateway";

  modules = [
    kix.flavors.kind
    {
      # region:gatewayInstance
      instances.gateway-system.gateway = {
        package = packages."envoy-gateway";
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
