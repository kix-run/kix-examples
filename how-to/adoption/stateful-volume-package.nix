# stateful-volume-package.nix: a renameable PVC for migration-gate examples.
#
# This is a fixture, not a pattern to copy. An application package that builds
# its own PersistentVolumeClaim fails evaluation; the supported shape is a
# `storage` dependency on a separate persistent-volume-claim instance, which
# leaves size, StorageClass and lifecycle with the cluster operator. See
# /docs/how-to/package-task-guides/provision-persistent-storage/.
#
# The `meta.unsafe = [ "raw-pvc" ]` grant below is the explicit escape from
# that rule. It exists here because these examples need to rename a claim on
# demand to trigger the stateful migration gate, which is the thing being
# demonstrated. Every grant is listed by the scorecard's `unsafeGrants` audit,
# so it stays visible rather than becoming a quiet exception.
#
# The claim's StorageClass comes from the `storageClasses` dependency, which
# the kind flavor's platform import answers.

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
    {
      self,
      config,
      storageClasses,
      ...
    }:
    {
      claim = scope.mkResource {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        name = config.claimName;
        spec = {
          storageClassName = storageClasses.out.storageClassName;
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = config.size;
        };
      };

      root = self.claim;
    };
}
