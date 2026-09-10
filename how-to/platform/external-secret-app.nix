# external-secret-app.nix: a package that consumes an existing Secret without
# managing its data.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Application with an externally managed Secret";
  };

  build =
    { self, ... }:
    {
      # region:externalSecretRef
      credentials = scope.mkSecretRef {
        name = "billing-api-credentials";
        keys = [ "api-key" ];
      };
      # endregion:externalSecretRef

      # region:externalSecretEnv
      deployment = scope.mkDeployment {
        name = scope.instanceName;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [
            {
              name = "app";
              image = "busybox:1.36";
              command = [ "sh" "-c" "sleep 3600" ];
              env = self.credentials.out.mkEnv {
                BILLING_API_KEY = "api-key";
              };
            }
          ];
        };
      };
      # endregion:externalSecretEnv

      root = self.deployment;
    };
}
