# how-to-package-monitoring-loki: add Loki to the native monitoring stack.
#
# Recommended reading: how-to-package-monitoring.
#
# What's new: one module option adds a log store, its volume, and the
# Grafana datasource for it.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-monitoring-loki";

  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    (
      { config, ... }:
      {
        imports = [ kix.modules.monitoring ];

        # region:lokiStack
        monitoring = {
          enabled = true;

          # Keep the local example independent of a Grafana volume.
          grafana.persistence.enabled = false;

          # Loki runs beside Grafana on a claim named loki-storage. Grafana
          # gets a Loki datasource, and the module's log shipper sends every
          # pod's logs to it.
          loki = {
            enabled = true;
            storageSize = "5Gi";
          };
        };

        # Loki's own configuration, merged over the package's.
        instances.${config.monitoring.namespace}.loki.config.settings = {
          limits_config.retention_period = "72h";
        };
        # endregion:lokiStack
      }
    )
  ];
}
