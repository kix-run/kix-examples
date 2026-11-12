# Return the module list for homelab on kind with Gateway API in place of
# ingress-nginx.
#
# cluster-kind-gateway-migrate.nix uses it with the cluster name
# `homelab-kind`, so deploying it over a `homelab-kind` activation is an
# upgrade. Kix prunes ingress-nginx and the Ingresses and creates the
# GatewayClass, Gateway and HTTPRoutes in the same activation history.

{ kix, packages }:

{
  modules = [
    kix.flavors.kind
    ./base.nix

    (
      { lib, ... }:
      {
        # ─── Cilium (same as homelab-kind) ───────────────────────────
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
        instances.monitoring-system.loki-logs.config.healthCheck.enabled = true;

        # ─── Gateway API L7 ──────────────────────────────────────────
        # envoy-gateway provides the `gateway` DI alias consumed by
        # kix.expose, so every exposed service emits an HTTPRoute bound
        # to this Gateway. Controller + Gateway API CRDs are installed
        # by the deploy scripts before `kix deploy`.
        instances.gateway-system.gateway = {
          package = packages.experimental."envoy-gateway";
          config = {
            controllerName = "gateway.envoyproxy.io/gatewayclass-controller";
            listeners = [
              {
                name = "http";
                port = 80;
                protocol = "HTTP";
                allowedRoutes.namespaces.from = "All";
              }
            ];
            # Envoy Gateway provisions a LoadBalancer Service for the data
            # plane by default. kind has no LoadBalancer implementation, so
            # that Service never gets an address, the Gateway never reaches
            # Programmed=True, and `kix deploy` waits on a readiness that
            # cannot arrive. NodePort makes the controller publish the node
            # addresses instead.
            proxySpec.provider = {
              type = "Kubernetes";
              kubernetes.envoyService.type = "NodePort";
            };
          };
        };
      }
    )
  ];
}
