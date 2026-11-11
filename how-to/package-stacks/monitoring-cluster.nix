# how-to-package-monitoring: install the native monitoring stack.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: use a cluster module to configure a related package stack.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-monitoring";

  # region:monitoringStack
  # `kix.modules.experimental.monitoring` reads the package catalogue, which buildCluster
  # does not pass to modules on its own. specialArgs forwards it.
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      imports = [ kix.modules.experimental.monitoring ];

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
      # Grafana's administrator login. A real cluster keeps it in a SOPS
      # source or a secret-ref instead of the cluster file.
      instances.monitoring-system.grafana-admin = {
        package = packages.secret;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "development-only-password";
        };
      };
    }
  ];
  # endregion:monitoringStack
}
