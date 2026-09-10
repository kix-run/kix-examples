# how-to-platform-ingress: expose an application through ingress-nginx.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: the ingressNginx dependency makes kix.expose render an Ingress.

{ kix, packages, ... }:

let
  exposureApp = import ./exposure-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-ingress";

  modules = [
    kix.flavors.kind
    {
      # region:ingressControllerInstance
      instances.ingress-system.ingressNginx = {
        package = packages."ingress-nginx";
      };
      # endregion:ingressControllerInstance

      # region:ingressApplicationInstance
      instances.ingress-example.web = {
        package = exposureApp;
        config.ingress.host = "web.example.test";
      };
      # endregion:ingressApplicationInstance
    }
  ];
}
