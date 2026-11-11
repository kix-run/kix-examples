# how-to-platform-monitoring: create a ServiceMonitor for an application.
#
# Recommended reading: 06-service-dep (package dependencies).
#
# What's new: a Prometheus-compatible operator provides kix.monitor's builder.

{ kix, packages, ... }:

let
  monitoringApp = import ./monitoring-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-monitoring";

  modules = [
    kix.flavors.kind
    {
      # region:prometheusOperatorInstance
      instances.monitoring-system.prometheus = {
        package = packages.experimental."prometheus-operator";
      };
      # endregion:prometheusOperatorInstance

      # region:monitoredApplicationInstance
      instances.monitor-example.metrics = {
        package = monitoringApp;
        config.metrics.interval = "30s";
      };
      # endregion:monitoredApplicationInstance
    }
  ];
}
