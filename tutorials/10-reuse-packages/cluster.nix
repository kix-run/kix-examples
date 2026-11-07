# 10-reuse-packages — one package, many instances.
#
# Recommended reading: 09-typed-options (the reverse-proxy package
# here is a direct copy, including its `options`), and earlier
# examples (06, 08).
#
# What's new: the packages themselves do not change. Instead, the same
# echo-server package and reverse-proxy package are instantiated twice
# with different config. The blueprint lives in the package file; each
# deployed copy lives under `instances.<ns>.<name>`.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "10-reuse-packages";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        # region:reusedInstances
        namespaces = {
          app-v1 = { };
          app-v2 = { };
        };

        # ── v1 stack ───────────────────────────────────────────────
        # The two `package = ...` lines in v1 match the two
        # `package = ...` lines in v2. Only `config` and namespace
        # differ. That's the multi-instance pattern.
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
        # endregion:reusedInstances
      }
    )
  ];
}
