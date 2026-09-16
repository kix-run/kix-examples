# managed-secret-app.nix: a package that creates and consumes its own Secret.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Application with a Kix-managed development Secret";
  };

  build =
    { self, ... }:
    {
      # region:managedSecret
      credentials = scope.mkSecret {
        name = "${scope.instanceName}-credentials";
        stringData = {
          username = "demo";
          password = "development-only";
        };
      };
      # endregion:managedSecret

      # region:managedSecretEnv
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
                APP_USERNAME = "username";
                APP_PASSWORD = "password";
              };
            }
          ];
        };
      };
      # endregion:managedSecretEnv

      root = self.deployment;
    };
}
