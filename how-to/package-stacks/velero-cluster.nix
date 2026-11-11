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
      instances.velero-system = {
        # Secrets created outside Kix, with the keys the package reads.
        velero-credentials = {
          package = packages.secret-ref;
          aliases = [ "cloudCredentials" ];
          config.keys = [ "cloud" ];
        };
        velero-repo-credentials = {
          package = packages.secret-ref;
          aliases = [ "repositoryPassword" ];
          config.keys = [ "repository-password" ];
        };

        velero = {
          package = packages.experimental.velero;
          config = {
            backupStorageLocation = {
              objectStorage.bucket = "example-cluster-backups";
              config.region = "us-east-1";
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
      };
      # endregion:veleroInstance
    }
  ];
}
