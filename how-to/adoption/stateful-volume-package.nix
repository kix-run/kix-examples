# stateful-volume-package.nix: a renameable PVC for migration-gate examples.

{ scope, lib, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Stateful volume used to demonstrate migration detection";
    lifecycle = "stateful";
    scope = "namespace";
    unsafe = [ "raw-pvc" ];
  };

  options = {
    claimName = lib.mkOption {
      type = lib.types.str;
      description = "Kubernetes name of the claim";
    };
    size = lib.mkOption {
      type = lib.types.str;
      description = "Requested storage capacity";
    };
  };

  build =
    { self, config, ... }:
    {
      claim = scope.mkResource {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        name = config.claimName;
        spec = {
          storageClassName = "standard";
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = config.size;
        };
      };

      root = self.claim;
    };
}
