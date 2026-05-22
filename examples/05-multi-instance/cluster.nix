# 05-multi-instance — one package, many instances.
#
# Recommended reading: 04-typed-options (the reverse-proxy package
# here is a direct copy, including its `options`), and earlier
# examples (02, 03).
#
# What's new: nothing about the packages themselves. The new idea is
# that **one package can back any number of instances**. Below, the
# echo-server package and the reverse-proxy package each get
# instantiated twice — once per namespace — with different config.
# That's the package/instance split made concrete: blueprints in
# files, deployed copies in `instances.<ns>.<name>`.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "05-multi-instance";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        namespaces = {
          app-v1 = { };
          app-v2 = { };
        };

        # ── v1 stack ───────────────────────────────────────────────
        # Look closely: the two `package = ...` lines in v1 below
        # match the two `package = ...` lines in v2 — *exactly* the
        # same package values. Only `config` and namespace differ.
        # That's the multi-instance pattern in a nutshell.
        instances.app-v1 = {
          backend = {
            package = packages.echo-server;     # ← same package as in v2
            config.message = "Response from app-v1";
          };
          gateway = {
            package = reverseProxyPackage;      # ← same package as in v2
            config = {
              proxyPath = "/v1/";
              maxBodySize = "10m";
            };
            deps.backend = ref.app-v1.backend;
          };
        };

        # ── v2 stack ───────────────────────────────────────────────
        instances.app-v2 = {
          backend = {
            package = packages.echo-server;     # ← same package as in v1
            config.message = "Response from app-v2";
          };
          gateway = {
            package = reverseProxyPackage;      # ← same package as in v1
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
