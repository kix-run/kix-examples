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
      instances.cache = {
        valkey = {
          package = packages.valkey;
          config.storage.size = "2Gi";
        };

        # Outside local development, give the secret a SOPS `source` with
        # keys = [ "password" ], or use a secret-ref to an existing Secret.
        valkey-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "development-only-password";
        };
      };
      # endregion:valkeyInstance
    }
  ];
}
