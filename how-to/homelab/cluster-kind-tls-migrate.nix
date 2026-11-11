# homelab-kind-tls-migrate: add TLS to a running homelab-kind cluster.
#
# The cluster name is `homelab-kind`, so a deploy over a `homelab-kind`
# activation (plain HTTP) is an upgrade that adds TLS.
#
# Change from cluster-kind.nix: a self-signed ClusterIssuer. It needs
# cert-manager, so Kix adds cert-manager, and every package that uses
# `kix.expose` gets an Ingress with TLS. No service configuration changes.
#
# Deploying `homelab-kind` again removes cert-manager and the issuer, and
# the Ingresses go back to plain HTTP.
#
# Demo: demos/demo-tls-migration.sh

{ kix, packages }:

kix.buildCluster {
  # The shared name makes adding TLS an upgrade,
  # not a fresh install.
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, ... }:
      {
        # Cilium and network policies, as in homelab-kind.
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

        # ingress-nginx, as in homelab-kind.
        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };

        # The change from the baseline: a self-signed ClusterIssuer. It asks
        # for `certManager`, so cert-manager is auto-instantiated, and it
        # answers `clusterIssuer`, so every package that uses `kix.expose`
        # gets Ingress TLS.
        instances.cert-manager.selfsigned = {
          package = packages.experimental.cluster-issuer;
          config.spec.selfSigned = { };
        };
      }
    )
  ];
}
