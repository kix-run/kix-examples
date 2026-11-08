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
    # Per-service feature gates. Each app group in services.nix is wrapped
    # in `lib.mkIf config.homelab.features.<name>`. Every group but Home
    # Assistant is on by default. Its chart runs the container as root, which
    # the scorecard rejects at error severity.
    homelab.features =
      let
        enabled = description: lib.mkEnableOption description // { default = true; };
      in
      {
        immich = enabled "Immich photo backup";
        nas = enabled "NAS / filebrowser";
        vaultwarden = enabled "Vaultwarden password manager";
        homeassistant = lib.mkEnableOption "Home Assistant";
      };
  };
}
