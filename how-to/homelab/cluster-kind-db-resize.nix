# homelab-kind-db-resize: grow the database and the Loki volume.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Changes from cluster-kind.nix:
#   - StackGres persistentVolume.size goes from 50Gi to 100Gi.
#   - Loki storageSize goes from 5Gi to 10Gi.
#
# The two changes take different paths. StackGres owns the StatefulSet
# for Postgres, so the resize goes through the SGCluster resource and the
# operator decides how to apply it. Loki's PVC is a plain Kix resource, so
# Kix patches the claim directly.
#
# Demo: demos/demo-db-resize.sh

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

        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };

        # The change: larger database and Loki volumes.

        # StackGres postgres: 50Gi to 100Gi. This changes the SGCluster
        # CR's pods.persistentVolume.size, which the StackGres operator
        # reconciles into the backing StatefulSet's volumeClaimTemplates.
        instances.data.postgres.config.persistentVolume.size = lib.mkForce "100Gi";

        # Loki: 5Gi to 10Gi. Direct PVC resize through the monitoring
        # module's loki storageSize option.
        monitoring.loki.storageSize = lib.mkForce "10Gi";
      }
    )
  ];
}
