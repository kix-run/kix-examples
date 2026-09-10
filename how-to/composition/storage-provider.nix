# storage-provider.nix: a minimal infrastructure role provider.
#
# Recommended reading: how-to/composition/config-package.nix (package
# metadata).
#
# What's new: claim a registered infrastructure role and satisfy its output
# contract.

{ scope, ... }:

{
  # region:infrastructureRole
  meta = {
    version = "1.0.0";
    description = "Default StorageClass for the composition example";
    owner = "platform";
    roles = [ "storageClasses" ];
  };
  # endregion:infrastructureRole

  build =
    { self, ... }:
    {
      storageClass = scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        name = "example-local";
        extra = {
          provisioner = "kubernetes.io/no-provisioner";
          volumeBindingMode = "WaitForFirstConsumer";
        };
      };

      # region:roleOutputContract
      root = {
        resource = self.storageClass;
        out.storageClassName = self.storageClass.out.name;
      };
      # endregion:roleOutputContract
    };
}
