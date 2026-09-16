# web-package.nix: a small local package shared by the application how-to
# guides.
#
# Recommended reading: 09-typed-options (local packages and typed options).
#
# What's new: a reusable package with environment variables, a ConfigMap
# mount, and an optional post-deploy health check.

{
  scope,
  lib,
  kix,
}:

{
  # region:packageMetadata
  meta = {
    version = "1.0.0";
    description = "Small nginx application used by the Kix how-to guides";
  };
  # endregion:packageMetadata

  # region:typedOptions
  options = {
    message = lib.mkOption {
      type = lib.types.str;
      default = "Hello from Kix";
      description = "Text served from the application root.";
    };

    environment = lib.mkOption {
      type = lib.types.enum [
        "preview"
        "production"
      ];
      default = "preview";
      description = "Environment name exposed to the container.";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of application replicas.";
    };

    # region:healthCheckOption
    healthCheck = kix.options.healthCheck;
    # endregion:healthCheckOption
  };
  # endregion:typedOptions

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        ...
      }:
      let
        name = scope.instanceName;

        # region:configMount
        contentMount = kix.mount.configMap self.content {
          name = "content";
          mountPath = "/usr/share/nginx/html";
          readOnly = true;
        };
        # endregion:configMount
      in
      {
        # region:contentConfigMap
        content = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          inherit name;
          data."index.html" = "${config.message}\n";
        };
        # endregion:contentConfigMap

        # region:applicationDeployment
        deployment =
          {
            inherit name;
            spec = {
              replicas = config.replicas;
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                {
                  name = "nginx";
                  image = "docker.io/library/nginx:1.27-alpine";
                  imagePullPolicy = "IfNotPresent";
                  ports = [ (kix.port "http" 80) ];
                  # region:environmentVariables
                  env = kix.mkEnvVars {
                    APP_ENV = config.environment;
                  };
                  # endregion:environmentVariables
                  readinessProbe.httpGet = {
                    path = "/";
                    port = "http";
                  };
                  resources = {
                    requests = {
                      cpu = "10m";
                      memory = "16Mi";
                    };
                    limits.memory = "64Mi";
                  };
                }
              ];
            };
          }
          # region:applyMount
          |> kix.withMounts [ contentMount ]
          # endregion:applyMount
          |> scope.mkDeployment;
        # endregion:applicationDeployment

        # region:applicationService
        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
        # endregion:applicationService
      }
    )

    # region:healthCheckBuildEntry
    (kix.healthCheck {
      runtime = kix.healthCheck.runtimes.shell;
      env =
        { self, ... }:
        {
          APP_URL = self.service.out.url { };
        };
      script = builtins.readFile ./health-check.sh;
    })
    # endregion:healthCheckBuildEntry
  ];
}
