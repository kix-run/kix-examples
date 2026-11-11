# homelab-kind-pg17: upgrade Postgres from 16 to 17.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Change from cluster-kind.nix: StackGres postgres.version goes from "16"
# to "17".
#
# The SGCluster resource changes and the StackGres operator reconciles
# the running Postgres. The demo shows what `kix diff` reports and which
# objects a major version bump touches.
#
# Demo: demos/demo-pg-version-bump.sh

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, ... }:
      {
        # The deploy scripts create kind with disableDefaultCNI, so the cni role
        # is vacant; the managed cilium instance fills it.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        instances.kube-system.cilium = {
          package = packages.experimental.cilium;
        };

        monitoring.loki.storageSize = lib.mkDefault "5Gi";

        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };

        # The change: Postgres 16 to 17.
        # Switch the StackGres cluster from Postgres 16 to 17.
        # This changes:
        #   - SGCluster spec.postgres.version
        #   - Patroni container image tag (pg16 to pg17)
        #   - SGPostgresConfig name (includes the major)
        #   - Every consumer's DI hash (postgres packageinstance re-hashes)
        instances.data.postgres.config.postgres.version = lib.mkForce "17";
      }
    )
  ];
}
