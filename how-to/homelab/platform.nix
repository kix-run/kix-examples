# Platform: flavor-agnostic infra options for the homelab clusters.
#
# Both the L7 controller (Gateway API vs Ingress) and any default
# StorageClasses are wired by the cluster files because they differ
# between variants.
# Things that DO live here are options/labels/etc. that apply to all
# variants. LAN-only: no TLS, plain HTTP either way.

{ lib, ... }:
{
  options = {
    # Per-service feature gates for staged rollout. Each app group in
    # services.nix is wrapped in `lib.mkIf config.homelab.features.<name>`,
    # so the first real deploy can ship a minimal set and turn the rest
    # on one at a time.
    homelab.features = {
      immich = lib.mkEnableOption "Immich photo backup" // {
        default = true;
      };
      nas = lib.mkEnableOption "NAS / filebrowser";
      vaultwarden = lib.mkEnableOption "Vaultwarden password manager";
      homeassistant = lib.mkEnableOption "Home Assistant";
    };
  };
}
