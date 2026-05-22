# 06-scorecards — Kix's compile-time rule engine.
#
# Recommended reading: 05-multi-instance (the cluster body here is
# identical to 05's — two namespaces, two backend+gateway pairs),
# and earlier examples (02/03/04).
#
# What's new: the `scorecard = ...` line below. The cluster turns on
# Kix's rule engine and imports rules from ./scorecard.nix. The
# multi-instance shape stays in place so one rule can compare gateways
# across the whole cluster.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "06-scorecards";

  modules = [
    kix.flavors.kind

    # `lib` is injected by the NixOS module system — we pull it in
    # here so we can hand it to ./scorecard.nix on import.
    (
      { ref, lib, ... }:
      {
        # ── Scorecard ────────────────────────────────────────────────
        # The whole rules block lives in ./scorecard.nix. cluster.nix
        # stays focused on what the cluster *contains*; the rules file
        # owns the checks we want to run against it.
        scorecard = import ./scorecard.nix { inherit lib kix; };

        namespaces = {
          app-v1 = { };
          app-v2 = { };
        };

        instances.app-v1 = {
          backend = {
            package = packages.echo-server;
            config.message = "Response from app-v1";
          };
          gateway = {
            package = reverseProxyPackage;
            config = {
              proxyPath = "/v1/";
              maxBodySize = "10m";
            };
            deps.backend = ref.app-v1.backend;
          };
        };

        instances.app-v2 = {
          backend = {
            package = packages.echo-server;
            config.message = "Response from app-v2";
          };
          gateway = {
            package = reverseProxyPackage;
            config = {
              proxyPath = "/v2/";
              maxBodySize = "10m";
            };
            deps.backend = ref.app-v2.backend;
          };
        };
      }
    )
  ];
}
