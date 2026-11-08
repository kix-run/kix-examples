# homelab-kind-ns-rename: move File Browser from namespace `nas` to
# `filebrowser`.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation is an upgrade of that activation.
#
# Kubernetes cannot rename a namespace. Every object in `nas` gets a new
# identity in `filebrowser`, so Kix prunes the old objects and creates new
# ones. For the PVC this deletes the data, because the new claim in
# `filebrowser` starts empty.
#
# Demo: demos/demo-ns-rename.sh

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, config, ... }:
      let
        domain = config.cluster.domain;
      in
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

        # The change: File Browser moves from `nas` to `filebrowser`.
        # Move the NAS workload from namespace `nas` to `filebrowser`.
        # Same package, same config, different namespace identity.
        # This removes the `nas` instance block from services.nix and
        # re-declares it under `filebrowser`.
        #
        # Disable the original `nas` instance (services.nix declares it).
        instances.nas = lib.mkForce { };

        # Re-declare under the new namespace name.
        instances.filebrowser = {
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "200Gi";
          };

          filebrowser = {
            package = packages.filebrowser;
            config.ingress.host = "files.${domain}";
          };
        };
      }
    )
  ];
}
