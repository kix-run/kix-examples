# database-package.nix: catalog package for the auto-instantiation scenario.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Database endpoint for the auto-instantiation example";
  };

  build =
    { self, ... }:
    {
      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = scope.instanceName;
        data.engine = "postgresql";
      };

      root = self.configMap;
    };
}
