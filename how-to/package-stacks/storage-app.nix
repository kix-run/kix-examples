# storage-app.nix: consume a first-class PVC through dependency wiring.
#
# Recommended reading: 06-service-dep (dependencies and build parts).
#
# What's new: a storage dependency becomes a mounted PVC volume.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "1.0.0";
    description = "Application used by the persistent storage how-to";
  };

  build =
    {
      self,
      scope,
      kix,
      storage,
      ...
    }:
    {
      # region:persistentVolumeMount
      dataMount = kix.mount.pvc storage {
        mountPath = "/var/lib/app";
      };
      # endregion:persistentVolumeMount

      # region:persistentStorageDeployment
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
        |> kix.withMounts [ self.dataMount ]
        |> scope.mkDeployment;
      # endregion:persistentStorageDeployment

      root = self.deployment;
    };
}
