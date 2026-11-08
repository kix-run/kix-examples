# homelab-kind-upgrade-small: a one-line upgrade of homelab-kind.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Change from cluster-kind.nix: `monitoring.loki.storageSize` goes from
# 5Gi to 6Gi. This touches only the Loki PVC.
#
# Demo: demos/demo-upgrade-lane.sh

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
          package = packages.cilium;
        };

        # The only change from cluster-kind.nix.
        monitoring.loki.storageSize = lib.mkForce "6Gi";

        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages."ingress-nginx";
        };
      }
    )
  ];
}
