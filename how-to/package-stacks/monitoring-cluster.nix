# how-to-package-monitoring: install the native monitoring stack.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: use a cluster module to configure a related package stack.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-monitoring";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    # region:monitoringStack
    {
      imports = [ kix.modules.monitoring ];

      monitoring = {
        enabled = true;
        prometheus = {
          retention = "7d";
          scrapeInterval = "30s";
        };

        # Keep the local example independent of persistent storage.
        grafana.persistence.enabled = false;

        # Add the standard Kubernetes alerts, recording rules, and monitors.
        defaultRules.enabled = true;
      };
    }
    # endregion:monitoringStack
  ];
}
