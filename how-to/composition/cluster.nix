# how-to-composition: reusable fixture for cluster-settings guides.
#
# Recommended reading: how-to/application (local package authoring).
#
# What's new: namespace policy and cluster-wide settings.

{ kix, ... }:

let
  package = import ./config-package.nix;
  customResourcePackage = import ./custom-resource-package.nix;
  storageProvider = import ./storage-provider.nix;
in
kix.buildCluster {
  name = "how-to-composition";

  modules = [
    kix.flavors.kind
    {
      # region:clusterAndNamespaceSettings
      clusterDomain = "cluster.example";
      clusterLabels."platform.example.com/environment" = "development";
      k8sVersion = "1.36";

      namespaces.apps = {
        labels."platform.example.com/tier" = "application";
        annotations."platform.example.com/owner" = "platform";
        resourceQuota = {
          "requests.cpu" = "2";
          "requests.memory" = "2Gi";
        };
      };

      instances.apps.storefront = {
        inherit package;
        config.message = "Storefront configuration";
      };

      instances.apps.widget = {
        package = customResourcePackage;
      };

      instances._platform.storage = {
        package = storageProvider;
      };
      # endregion:clusterAndNamespaceSettings
    }
  ];
}
