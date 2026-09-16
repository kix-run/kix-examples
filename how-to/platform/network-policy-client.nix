# network-policy-client.nix: a workload that calls a Service dependency.
#
# Recommended reading: 08-namespace-deps (explicit cross-namespace deps).
#
# What's new: the Service endpoint also gives Kix the information needed to
# generate network policy for the connection.

{
  meta = {
    version = "1.0.0";
    description = "Client workload for the generated network policy how-to";
  };

  # region:trackedServiceEndpoint
  build =
    {
      self,
      scope,
      backend,
      ...
    }:
    {
      deployment = scope.mkDeployment {
        name = scope.instanceName;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [
            {
              name = "client";
              image = "docker.io/library/nginx:1.27-alpine";
              env = [
                {
                  name = "BACKEND_URL";
                  value = backend.out.url { };
                }
              ];
            }
          ];
        };
      };

      root = self.deployment;
    };
  # endregion:trackedServiceEndpoint
}
