# how-to-auto-instantiation: dependencies supplied from a package catalog or
# a dormant instance.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: availablePackages, optional instances, and autoNamespace.

{ kix, ... }:

let
  applicationPackage = import ./application-package.nix;
  databasePackage = import ./database-package.nix;
  metricsPackage = import ./metrics-package.nix;
in
kix.buildCluster {
  name = "how-to-auto-instantiation";

  modules = [
    kix.flavors.kind
    {
      namespaces.apps = { };
      namespaces.platform = { };

      # region:autoInstantiationCatalog
      # Catalog entries stay absent until a required package argument asks
      # for one. autoNamespace chooses where Kix creates the instance.
      availablePackages.database = {
        package = databasePackage;
      };
      autoNamespace = "platform";
      # endregion:autoInstantiationCatalog

      # region:optionalInstance
      # This configured instance is dormant until another package requires
      # an argument named `metrics`.
      instances.platform.metrics = {
        package = metricsPackage;
        optional = true;
        config.retentionDays = 14;
      };
      # endregion:optionalInstance

      # region:autoInstantiationConsumer
      # applicationPackage requires both `database` and `metrics`. That
      # demand creates the catalog package and activates the optional one.
      instances.apps.api = {
        package = applicationPackage;
      };
      # endregion:autoInstantiationConsumer
    }
  ];
}
