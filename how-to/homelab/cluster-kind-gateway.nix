# homelab-kind-gateway: homelab on kind with Gateway API from the start.
#
# Envoy Gateway is the only L7 controller this cluster ever has. To move a
# running `homelab-kind` cluster from ingress-nginx to Gateway API, use
# cluster-kind-gateway-migrate.nix instead.
#
# Demo: demos/deploy-homelab-kind-gateway.sh

{ kix, packages }:

kix.buildCluster {
  specialArgs = { inherit packages kix; };
  modules = (import ./_kind-gateway-modules.nix { inherit kix packages; }).modules;
}
