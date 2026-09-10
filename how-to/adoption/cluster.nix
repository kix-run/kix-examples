# how-to-adoption: reusable fixture for adopting existing resources.

{ kix, ... }:

let
  clientPackage = import ./client-package.nix;
in
kix.buildCluster {
  name = "how-to-adoption";

  modules = [
    kix.flavors.kind
    {
      namespaces = {
        apps = { };
        legacy = { };
      };

      instances = {
        legacy.legacy-api = {
          # region:importExistingService
          package = kix.mkImport {
            kind = "Service";
            apiVersion = "v1";
            out = {
              name = "legacy-api";
              fqdn = "legacy-api.legacy.svc.cluster.local";
              port = 8080;
            };
          };
          aliases = [ "legacyApi" ];
          # endregion:importExistingService
        };

        apps.client.package = clientPackage;
      };
    }
  ];
}
