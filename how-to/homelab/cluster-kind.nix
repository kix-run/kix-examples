# homelab-kind: the full homelab service set on a local kind cluster.
#
# This is the repository's smoke-test cluster. It wires together most of
# the package set (StackGres, Cilium, monitoring, Loki, Valkey, Immich,
# ingress-nginx), so `kix check homelab-kind` catches most regressions.
#
#   - kind flavor (ephemeral storage, no LoadBalancer)
#   - ingress-nginx for routing (cluster-kind-gateway.nix routes through
#     envoy-gateway instead)

{ kix, packages }:

kix.buildCluster {
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, ... }:
      {
        # ─── Cilium network policies ─────────────────────────────────
        # kix owns the full cilium lifecycle on kind: the helm-wrapped
        # `cilium` package emits the DaemonSet + CRDs + all the supporting
        # RBAC, and the netpol plugin routes every generated CNP through
        # the DaemonSet's root via the CRD reference exposed as
        # `out.crds.CiliumNetworkPolicy`. No external helm install, no out-of-band
        # ordering. Requires `kind create cluster` to run with the
        # default CNI disabled so cilium
        # can take over the CNI slot.
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

        # Smaller Loki PVC for kind.
        monitoring.loki.storageSize = lib.mkDefault "5Gi";

        # The probe passes once Loki has acknowledged a new push from an
        # agent.
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        # Legacy Ingress L7. ingress-nginx provides the `ingressNginx` DI
        # alias that kix.expose consumes to emit Ingress resources instead
        # of HTTPRoutes.
        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };
      }
    )
  ];
}
