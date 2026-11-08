# The homelab services and platform, shared by every homelab cluster.
#
# The clusters that import this file (cluster-kind.nix and the gateway
# variants) add the flavor and the L7 controller. Keep this file free of
# flavor-specific settings.

{
  packages,
  kix,
  lib,
  config,
  ...
}:

{
  imports = [
    ./platform.nix
    ./services.nix
    kix.modules.monitoring
  ];

  # Auto-instantiate deps (coredns, valkey, stackgres-operator, etc.)
  availablePackages = packages;

  cluster.domain = "homelab.lan";
  clusterLabels = {
    "app.kubernetes.io/part-of" = "homelab";
    "cluster" = "homelab";
  };

  # Monitoring stack (was monitoring.nix). Provides prometheus-operator,
  # prometheus, alertmanager, node-exporter, kube-state-metrics, grafana,
  # plus Loki and the loki-logs agent.
  monitoring = {
    enabled = true;
    # mkDefault so a variant can switch Loki off without an mkForce.
    loki.enabled = lib.mkDefault true;
    defaultRules.enabled = true;
  };

  # Grafana takes no host from cluster.domain, because its route also serves
  # its unauthenticated /metrics.
  instances.monitoring-system.grafana.config.ingress.host = "grafana.${config.cluster.domain}";

  # Grafana applies GF_SECURITY_ADMIN_PASSWORD only when it creates its
  # database, so a password changed in the UI or rotated in the
  # grafana-admin secret would otherwise never take effect. The
  # init container sync-admin-password resets the administrator's password to
  # the secret's value on every start. Without grafana.db (first start) it
  # does nothing, and Grafana creates the administrator from the env.
  # mkDeployment seals the workload, so the overlay rebuilds the `deployment`
  # part from the package's spec with the init container appended.
  instances.monitoring-system.grafana.partsOverlays = [
    (
      scope: _self: base:
      let
        manifest = base.deployment.rawManifest;
        podSpec = manifest.spec.template.spec;
        grafana = lib.findFirst (
          c: c.name == "grafana"
        ) (throw "homelab: the grafana Deployment has no container named grafana") podSpec.containers;
        syncAdmin = {
          name = "sync-admin-password";
          inherit (grafana)
            image
            imagePullPolicy
            env
            securityContext
            resources
            ;
          command = [
            "sh"
            "-c"
            ''
              [ -f "$GF_PATHS_DATA/grafana.db" ] || exit 0
              printf '%s' "$GF_SECURITY_ADMIN_PASSWORD" | grafana cli \
                --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
                admin reset-admin-password --password-from-stdin
            ''
          ];
          volumeMounts = builtins.filter (
            m:
            builtins.elem m.name [
              "tmp"
              "config"
              "storage"
            ]
          ) grafana.volumeMounts;
        };
      in
      {
        deployment = scope.mkDeployment {
          name = manifest.metadata.name;
          availability.max = "none";
          spec = manifest.spec // {
            template = manifest.spec.template // {
              # After init-chown-data, when enabled, so the reset can write
              # grafana.db.
              spec = podSpec // {
                initContainers = (podSpec.initContainers or [ ]) ++ [ syncAdmin ];
              };
            };
          };
        };
      }
    )
  ];

  # Grafana's administrator login. The homelab clusters are for local
  # testing, so the password is a literal. A real deployment sets `source`
  # to a SOPS file instead.
  instances.monitoring-system.grafana-admin = {
    package = packages.secret;
    aliases = [ "grafanaAdmin" ];
    config = {
      keys = [
        "admin-user"
        "admin-password"
      ];
      stringData = {
        admin-user = "admin";
        admin-password = "dev-password";
      };
    };
  };

  # The full rule set at built-in severities, with the cap raised to error
  # so that an error-severity finding fails the build.
  scorecard = {
    maxSeverity = "error";
    # Charts such as cilium-envoy emit prometheus.io scrape annotations by
    # convention, and no package declares that domain, so list it here.
    knownAnnotationDomains = [ "prometheus.io" ];
  };
}
