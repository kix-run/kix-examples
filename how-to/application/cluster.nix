# how-to-application: reusable fixture for application-authoring guides.
#
# Recommended reading: 09-typed-options (local packages and typed options).
#
# What's new: two instances of one local package, with a post-deploy health
# check enabled for the production instance.

{ kix, ... }:

let
  # region:localPackageImport
  webPackage = import ./web-package.nix;
  # endregion:localPackageImport
in
kix.buildCluster {
  name = "how-to-application";

  modules = [
    # region:kindFlavor
    kix.flavors.kind
    # endregion:kindFlavor

    {
      namespaces.how-to-app = { };

      # region:reusedInstances
      instances.how-to-app = {
        preview = {
          package = webPackage;
          config = {
            message = "Hello from preview";
            environment = "preview";
          };
        };

        production = {
          package = webPackage;
          config = {
            message = "Hello from production";
            environment = "production";
            replicas = 2;
            # region:healthCheckConfig
            healthCheck = {
              enabled = true;
              retryFor = 60;
            };
            # endregion:healthCheckConfig
          };
        };
      };
      # endregion:reusedInstances
    }
  ];
}
