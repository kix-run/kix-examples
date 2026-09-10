# metrics-package.nix: configured optional package for the auto-instantiation
# scenario.

{
  scope,
  lib,
  ...
}:

{
  meta = {
    version = "1.0.0";
    description = "Metrics endpoint for the auto-instantiation example";
  };

  options.retentionDays = lib.mkOption {
    type = lib.types.int;
    default = 7;
    description = "Number of days to retain metrics.";
  };

  build =
    {
      self,
      config,
      ...
    }:
    {
      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = scope.instanceName;
        data.retentionDays = toString config.retentionDays;
      };

      root = self.configMap // {
        out = self.configMap.out // {
          endpoint = "http://${self.configMap.out.fqdn}:9090";
        };
      };
    };
}
