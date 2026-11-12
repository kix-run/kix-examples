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
        package = packages.experimental."envoy-gateway";
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

    # Envoy Gateway provisions a LoadBalancer Service for the data plane by
    # default. kind ships no LoadBalancer implementation, so that Service
    # would sit at <pending> forever, the Gateway would stay
    # Programmed=False, and `kix deploy` would wait on a readiness that
    # cannot arrive. NodePort makes Envoy Gateway publish the node
    # addresses instead. A cloud cluster wants the default, so this stays
    # a separate module rather than part of the gateway instance above.
    {
      # region:gatewayKindProxy
      instances.gateway-system.gateway.config.proxySpec.provider = {
        type = "Kubernetes";
        kubernetes.envoyService.type = "NodePort";
      };
      # endregion:gatewayKindProxy
    }
  ];
}
