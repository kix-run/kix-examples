# homelab-kind-upgrade-broad: change one input that many objects use.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Change from cluster-kind.nix: `cluster.domain` goes from "homelab.lan"
# to "homelab-v2.lan". Every host that `kix.expose` derives from the
# domain changes. Compare with cluster-kind-upgrade-small.nix in the
# blast-radius demo.
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

        monitoring.loki.storageSize = lib.mkDefault "5Gi";

        # The change: one cluster-level input that many downstream
        # resources affected. Every Ingress host derived from
        # `${name}.${domain}` re-renders, and the cluster activation
        # manifest re-hashes.
        cluster.domain = lib.mkForce "homelab-v2.lan";

        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages."ingress-nginx";
        };
      }
    )
  ];
}
