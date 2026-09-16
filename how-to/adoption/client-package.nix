# client-package.nix: a small consumer for the adoption how-to guides.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Configuration for a client of an existing service";
  };

  build =
    {
      legacyApi,
      self,
      ...
    }:
    {
      # region:consumeImportedService
      clientConfig = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "legacy-api-client";
        data.endpoint = "http://${legacyApi.out.fqdn}:${toString legacyApi.out.port}";
      };

      root = self.clientConfig;
      # endregion:consumeImportedService
    };
}
