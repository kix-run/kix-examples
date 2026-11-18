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
        # envoy-gateway-controller installs the controller. envoy-gateway
        # adds a Gateway and provides the `gateway` DI alias consumed by
        # kix.expose, so every exposed service emits an HTTPRoute bound to
        # that Gateway. gateway-api installs the CRDs.
        # The kind flavour binds the loadBalancer role absent, so the proxy
        # Service is a NodePort.
        instances.gateway-system = {
          gateway-api.package = packages.experimental.gateway-api;
          envoy-gateway-controller.package = packages.experimental.envoy-gateway-controller;
          gateway = {
            package = packages.experimental.envoy-gateway;
            config.listeners = [
              {
                name = "http";
                port = 80;
                protocol = "HTTP";
                allowedRoutes.namespaces.from = "All";
              }
            ];
          };
        };
      }
    )
  ];
}
