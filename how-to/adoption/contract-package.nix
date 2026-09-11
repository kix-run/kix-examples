# contract-package.nix: configuration that must precede the imported API marker.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Compatibility contract for the legacy API";
  };

  build =
    { self, ... }:
    {
      contract = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "legacy-api-contract";
        data = {
          apiVersion = "v1";
          owner = "platform-team";
        };
      };

      root = self.contract;
    };
}
