# monitoring-app.nix: a service that exposes Prometheus metrics.
#
# Recommended reading: 06-service-dep (workloads, Services, and build entries).
#
# What's new: kix.monitor creates a ServiceMonitor from a package Service.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "1.0.0";
    description = "Metrics service used by the automatic monitoring how-to";
  };

  # region:monitorOption
  options.metrics = kix.options.monitor;
  # endregion:monitorOption

  build = [
    (
      {
        self,
        scope,
        kix,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = scope.instanceName;
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "metrics";
                image = "docker.io/prom/statsd-exporter:v0.29.0";
                ports = [ (kix.port "metrics" 9102) ];
              }
            ];
          };
        };

        service =
          self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;

        root = self.service;
      }
    )

    # region:monitorBuildEntry
    (kix.monitor {
      service = "service";
      port = "metrics";
    })
    # endregion:monitorBuildEntry
  ];
}
