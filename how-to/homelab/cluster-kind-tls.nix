# homelab-kind-tls: homelab on kind with HTTPS.
#
# The same packages as `homelab-kind`, plus cert-manager and a self-signed
# ClusterIssuer. Every package that uses `kix.expose` gets an Ingress with
# TLS. Nothing outside the kind cluster is needed: no Let's Encrypt and no
# DNS solver.
#
# Each install creates its own CA, so browsers warn about the
# certificate. This cluster tests how Kix wires TLS, not certificate
# trust.
#
# Demo: demos/deploy-homelab-kind-tls.sh

{ kix, packages }:

kix.buildCluster {
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
          package = packages.cilium;
        };

        monitoring.loki.storageSize = lib.mkDefault "5Gi";

        # ingress-nginx, because `kix.expose` adds TLS only to Ingresses.
        # With Gateway API, TLS belongs to the Gateway's listeners.
        # As in homelab-kind, so this setting is not part of the change.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        instances.ingress-nginx.ingress-nginx = {
          package = packages."ingress-nginx";
        };

        # A self-signed ClusterIssuer. It asks for `certManager`, so
        # cert-manager is auto-instantiated, and it answers `clusterIssuer`,
        # so every package that uses `kix.expose` gets Ingress TLS.
        # region:selfSignedClusterIssuer
        instances.cert-manager.selfsigned = {
          package = packages.cluster-issuer;
          config.spec.selfSigned = { };
        };
        # endregion:selfSignedClusterIssuer
      }
    )
  ];
}
