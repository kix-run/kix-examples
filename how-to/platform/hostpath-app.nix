# hostpath-app.nix: mount a directory from the Kubernetes node.
#
# Recommended reading: 06-service-dep (workloads and build parts).
#
# What's new: kix.mount.hostPath describes a node-local volume and mount.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "1.0.0";
    description = "Application used by the hostPath mount how-to";
  };

  build =
    {
      self,
      scope,
      kix,
      ...
    }:
    {
      # region:hostPathMount
      cacheMount = kix.mount.hostPath {
        name = "cache";
        hostPath = "/var/lib/example-cache";
        mountPath = "/var/cache/app";
        type = "DirectoryOrCreate";
      };
      # endregion:hostPathMount

      # region:hostPathDeployment
      deployment =
        {
          name = scope.instanceName;
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "worker";
                image = "docker.io/library/busybox:1.37";
                command = [
                  "sh"
                  "-c"
                  "sleep infinity"
                ];
              }
            ];
          };
        }
        |> kix.withMounts [ self.cacheMount ]
        |> scope.mkDeployment;
      # endregion:hostPathDeployment

      root = self.deployment;
    };
}
