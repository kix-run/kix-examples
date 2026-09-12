# sops-secret-app.nix: decrypt a SOPS file only when Kix deploys the Secret.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Application using a SOPS-backed Secret";
  };

  build =
    { self, ... }:
    {
      # region:sopsBackedSecret
      credentials = scope.mkSecret {
        name = "${scope.instanceName}-credentials";
        keys = [
          "username"
          "password"
        ];
        source = ./sops-credentials.enc.yaml;
      };
      # endregion:sopsBackedSecret

      # region:sopsSecretEnv
      deployment = scope.mkDeployment {
        name = scope.instanceName;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [
            {
              name = "app";
              image = "busybox:1.36";
              command = [
                "sh"
                "-c"
                "sleep 3600"
              ];
              env = self.credentials.out.mkEnv {
                APP_USERNAME = "username";
                APP_PASSWORD = "password";
              };
            }
          ];
        };
      };
      # endregion:sopsSecretEnv

      root = self.deployment;
    };
}
