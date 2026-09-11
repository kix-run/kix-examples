# how-to-adoption-takeover: move a kubectl-managed workload under Kix.
#
# Recommended reading: 13-imports-and-existing-cluster-resources and
# 20-adoption-and-migration.
#
# What's new: preserve an existing selector before Kix takes field ownership.

{ kix, ... }:

let
  webPackage = import ../application/web-package.nix;
in
kix.buildCluster {
  name = "how-to-adoption-takeover";

  modules = [
    kix.flavors.kind
    {
      namespaces.takeover = { };

      # region:kubectlManagedWorkload
      instances.takeover.legacy-web = {
        package = webPackage;

        # Keep the live Deployment's immutable selector.
        selectorLabels = {
          app = "legacy-web";
          tier = "frontend";
        };

        config = {
          replicas = 2;
          environment = "production";
          message = "This workload is managed by Kix";
        };
      };
      # endregion:kubectlManagedWorkload
    }
  ];
}
