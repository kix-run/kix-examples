# application-package.nix: a consumer used to demonstrate demand-driven
# package selection.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Application configuration with platform dependencies";
  };

  # region:autoInstantiatedDeps
  build =
    {
      self,
      database,
      metrics,
      ...
    }:
    {
      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = scope.instanceName;
        data = {
          databaseResource = database.out.name;
          metricsEndpoint = metrics.out.endpoint;
        };
      };

      root = self.configMap;
    };
  # endregion:autoInstantiatedDeps
}
