# how-to-adoption: reusable fixture for adopting existing resources.

{ kix, ... }:

let
  clientPackage = import ./client-package.nix;
  contractPackage = import ./contract-package.nix;
  webPackage = import ../application/web-package.nix;
in
kix.buildCluster {
  name = "how-to-adoption";

  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
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

            # region:explicitImportOrdering
            extraDeps = [ ref.apps.legacy-api-contract.root ];
            # endregion:explicitImportOrdering
          };

          apps.legacy-api-contract.package = contractPackage;

          apps.client = {
            package = clientPackage;

            # region:patchPackageOutput
            partsOverlays = [
              (
                scope: _self: base:
                let
                  patchedConfig = scope.mkResource {
                    inherit (base.clientConfig) apiVersion kind name;
                    inherit (base.clientConfig.rawManifest) data;
                    annotations."example.com/adopted-from" = "legacy-config";
                  };
                in
                {
                  clientConfig = patchedConfig;
                  root = patchedConfig;
                }
              )
            ];
            # endregion:patchPackageOutput
          };

          # region:preserveExistingSelectors
          apps.legacy-web = {
            package = webPackage;
            selectorLabels = {
              app = "legacy-web";
              tier = "frontend";
            };
            config = {
              message = "Kix now manages this workload";
              environment = "production";
            };
          };
          # endregion:preserveExistingSelectors

          # region:preserveHelmLabels
          apps.helm-web = {
            package = webPackage;
            labelStyle = "helm";
            config = {
              message = "Kix manages a Helm-labelled workload";
              environment = "production";
            };
          };
          # endregion:preserveHelmLabels
        };
      }
    )
  ];
}
