# how-to-package-victoria-metrics: install the VictoriaMetrics HA stack.
#
# Recommended reading: 09-typed-options (package configuration) and
# 12-flavors-capabilities-and-platform-app-boundaries (platform packages).
#
# What's new: compose an operator-backed monitoring stack through dependency
# injection, with HA defaults owned by the catalogue packages.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-victoria-metrics";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      namespaces.monitoring-system = { };

      # region:victoriaMetricsHaStack
      instances.monitoring-system = {
        vm-operator = {
          package = packages.victoria-metrics-operator;
        };

        vm-cluster = {
          package = packages.victoria-metrics-cluster;
          config = {
            retentionPeriod = "30d";
            vmstorage.storage.resources.requests.storage = "20Gi";
          };
        };

        vm-agent = {
          package = packages.victoria-metrics-agent;
          config.externalLabels.cluster = "example";
        };

        vm-alert = {
          package = packages.victoria-metrics-alert;
        };

        grafana = {
          package = packages.grafana;
        };
        # Grafana's administrator login. A real cluster keeps it in a SOPS
        # source or a secret-ref instead of the cluster file.
        grafana-admin = {
          package = packages.secret;
          aliases = [ "grafanaAdmin" ];
          config.stringData = {
            admin-user = "admin";
            admin-password = "development-only-password";
          };
        };
      };
      # endregion:victoriaMetricsHaStack
    }
  ];
}
