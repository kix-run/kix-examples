# homelab-kind-pvc-resize: grow the application volumes.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Changes from cluster-kind.nix:
#   - immich storage goes from 100Gi to 200Gi.
#   - nas storage goes from 200Gi to 300Gi.
#   - vaultwarden storage goes from 1Gi to 2Gi.
#
# Only `spec.resources.requests.storage` changes on each claim. A real
# cluster needs a StorageClass with `allowVolumeExpansion: true`. On kind
# the claims update but the hostPath volumes enforce no size.
#
# Demo: demos/demo-pvc-resize.sh

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
          package = packages.cilium;
        };

        monitoring.loki.storageSize = lib.mkDefault "5Gi";

        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages."ingress-nginx";
        };

        # The NAS and Vaultwarden features are off on the kind baseline; this
        # variant resizes their claims, so it turns them on.
        homelab.features.nas = true;
        homelab.features.vaultwarden = true;

        # The change: larger application volumes.
        # Override the storage sizes defined in services.nix.
        # Each of these touches exactly one PVC manifest per namespace.
        instances.immich.storage.config.size = lib.mkForce "200Gi";
        instances.nas.storage.config.size = lib.mkForce "300Gi";
        instances.vaultwarden.storage.config.size = lib.mkForce "2Gi";
      }
    )
  ];
}
