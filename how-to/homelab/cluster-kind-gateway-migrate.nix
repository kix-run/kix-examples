# homelab-kind-gateway-migrate: homelab-kind moved from ingress-nginx to
# Gateway API.
#
# The cluster name is `homelab-kind`, the same as cluster-kind.nix, so Kix
# treats a deploy of this cluster over a `homelab-kind` activation as an
# upgrade of that activation, not a new cluster.
#
# Demos: demos/deploy-homelab-kind-gateway-migrate.sh and
# demos/rollback-homelab-kind-gateway-migration.sh

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = (import ./_kind-gateway-modules.nix { inherit kix packages; }).modules;
}
