# how-to-package-valkey: deploy one persistent Valkey node.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: configure the catalogue's Valkey package for a small cluster.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-valkey";

  modules = [
    kix.flavors.kind
    {
      # region:valkeyInstance
      instances.cache.valkey = {
        package = packages.valkey;
        config = {
          replicaCount = 1;
          sentinel.enabled = false;

          persistence = {
            enabled = true;
            size = "2Gi";
          };

          # Use SOPS or an existing Secret outside local development.
          auth.password = "development-only-password";
        };
      };
      # endregion:valkeyInstance
    }
  ];
}
