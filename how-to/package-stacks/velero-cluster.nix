# how-to-package-velero: deploy Velero against existing object storage.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: configure backup storage and a recurring backup schedule.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-velero";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      # region:veleroInstance
      instances.velero-system.velero = {
        package = packages.velero;
        config = {
          credentials.secretName = "velero-credentials";

          backupStorageLocation = {
            provider = "velero.io/aws";
            bucket = "example-cluster-backups";
            config = {
              region = "eu-central-1";
              s3ForcePathStyle = "false";
            };
          };

          schedules.daily = {
            schedule = "0 2 * * *";
            template = {
              includedNamespaces = [ "applications" ];
              ttl = "720h0m0s";
              defaultVolumesToFsBackup = true;
            };
          };
        };
      };
      # endregion:veleroInstance
    }
  ];
}
