# how-to-package-stackgres: deploy a PostgreSQL cluster with StackGres.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: install an operator and configure a custom resource it manages.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-stackgres";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      # region:stackgresOperatorInstance
      instances.stackgres-system.stackgres-operator = {
        package = packages.stackgres-operator;
      };
      # endregion:stackgresOperatorInstance

      # region:stackgresClusterInstance
      instances.database.postgres = {
        package = packages.stackgres-cluster;
        config = {
          instances = 1;
          postgres.version = "16";
          storage.size = "5Gi";
          instanceProfile = {
            cpu = "500m";
            memory = "1Gi";
          };
        };
      };
      # endregion:stackgresClusterInstance
    }
  ];
}
