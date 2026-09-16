# exposure-app.nix: a small web package exposed through the cluster's routing
# capability.
#
# Recommended reading: 06-service-dep (workloads, Services, and build entries).
#
# What's new: kix.expose selects Ingress or Gateway API from dependency wiring.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "1.0.0";
    description = "Web application used by the platform exposure how-to guides";
  };

  # region:exposureOption
  options.ingress = kix.options.ingress;
  # endregion:exposureOption

  build = [
    (
      {
        self,
        scope,
        kix,
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
                name = "nginx";
                image = "docker.io/library/nginx:1.27-alpine";
                ports = [ (kix.port "http" 80) ];
              }
            ];
          };
        };

        service =
          self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;

        root = self.service;
      }
    )

    # region:exposureBuildEntry
    (kix.expose { service = "service"; })
    # endregion:exposureBuildEntry
  ];
}
