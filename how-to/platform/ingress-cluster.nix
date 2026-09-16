# how-to-platform-ingress: expose an application through ingress-nginx.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: the ingressNginx dependency makes kix.expose render an Ingress.
# The instance is named `ingress-nginx`, not `ingressNginx`: a package names
# its resources after its instance, and Kubernetes object names are lowercase.
# The package's `meta.defaultAliases` keeps the `ingressNginx` dependency name.

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
      instances.ingress-system."ingress-nginx" = {
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
