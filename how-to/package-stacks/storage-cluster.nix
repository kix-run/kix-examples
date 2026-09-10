# how-to-package-storage: provision a PVC and mount it into an application.
#
# Recommended reading: 06-service-dep (local packages and dependencies).
#
# What's new: the PVC is a first-class instance resolved as storage.

{ kix, packages, ... }:

let
  storageApp = import ./storage-app.nix;
in
kix.buildCluster {
  name = "how-to-package-storage";

  modules = [
    kix.flavors.kind
    {
      # region:persistentStorageInstances
      instances.storage-example.storage = {
        package = packages."persistent-volume-claim";
        config = {
          size = "5Gi";
          accessModes = [ "ReadWriteOnce" ];
        };
      };

      instances.storage-example.worker = {
        package = storageApp;
      };
      # endregion:persistentStorageInstances
    }
  ];
}
