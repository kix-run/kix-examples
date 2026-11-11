# homelab-kind-storage-migrate: move the application volumes to a new
# StorageClass.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation (or another variant in the chain) is an upgrade.
#
# Changes from cluster-kind.nix:
#   - The platform StorageClass becomes `kind-fast`.
#   - Every application PVC uses `kind-fast`.
#
# Kubernetes refuses a change to `spec.storageClassName` on a bound PVC.
# On a real cluster this migration needs a backup, a new claim and a
# restore. `kix diff` shows that the change replaces the claims.
#
# Demo: demos/demo-storage-migrate.sh

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, config, ... }:
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

        # Vaultwarden is off on the kind baseline; this variant migrates its
        # claim too, so it turns the feature on.
        homelab.features.vaultwarden = true;

        # The change: a new StorageClass.
        # 1. Override the platform storage import. The kind flavor
        #    injects `platform-storage` with storageClassName = "standard";
        #    we replace it with "kind-fast" to simulate a provisioner
        #    upgrade (for example local-path to ZFS). Every PVC that consumes
        #    `storageClasses` through DI picks up the new class name
        #    automatically, with no per-PVC changes needed for the class switch.
        instances.kube-system.platform-storage = lib.mkForce {
          package = kix.mkImport {
            kind = "StorageClass";
            apiVersion = "storage.k8s.io/v1";
            out = {
              name = "kind-fast";
              storageClassName = "kind-fast";
            };
          };
          aliases = [ "storageClasses" ];
        };

        # 2. Also override PVC sizes to make the diff more visible.
        instances.immich.storage.config.size = lib.mkForce "200Gi";
        instances.vaultwarden.storage.config.size = lib.mkForce "2Gi";
      }
    )
  ];
}
