# how-to-platform-cloudflare-tunnel: connect a Service to a remotely managed
# Cloudflare Tunnel.
#
# Recommended reading: 16-secrets (SOPS-backed Secrets).
#
# What's new: cloudflared reaches an in-cluster Service without an Ingress or
# LoadBalancer.

{ kix, packages, ... }:

let
  exposureApp = import ./exposure-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-cloudflare-tunnel";

  modules = [
    kix.flavors.kind
    {
      # region:tunnelOriginInstance
      instances.cloudflare-example.web = {
        package = exposureApp;
      };
      # endregion:tunnelOriginInstance

      # region:cloudflaredInstance
      instances.tunnel-system = {
        cloudflared = {
          package = packages.experimental.cloudflared;
          config = {
            image = {
              repository = "cloudflare/cloudflared";
              tag = "2026.9.0";
            };
            replicas = 2;
          };
        };

        # The tunnel token, decrypted from the SOPS file at deploy. The
        # alias is the dependency name cloudflared reads it under.
        tunnel-token = {
          package = packages.secret;
          aliases = [ "tunnelToken" ];
          config = {
            keys = [ "token" ];
            source = ./cloudflare-token.enc.yaml;
          };
        };
      };
      # endregion:cloudflaredInstance
    }
  ];
}
