# 09-typed-options — typed package config via `lib.mkOption`.
#
# Recommended reading: 06-service-dep (packages + deps),
# 08-namespace-deps (`ref`). This file assumes you know what
# `package`, `config`, `deps`, and `ref` mean.
#
# What's new: the gateway's `config` block now has typed knobs
# (`proxyPath`, `maxBodySize`) declared and validated by the package
# in ./reverse-proxy-package.nix. Bad values fail during `nix build`,
# before nginx ever sees them.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "09-typed-options";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        namespaces = {
          tutorial-09 = { };
        };

        instances.tutorial-09 = {
          backend = {
            package = packages.echo-server;
            config = {
              message = "Hello from the backend!";
            };
          };

          # region:configuredGateway
          gateway = {
            package = reverseProxyPackage;

            # Both options are typed in the package. Try a
            # `proxyPath` that does not start with `/`, or a
            # `maxBodySize` such as "1mb" (wrong suffix), and the
            # build will fail with a type error.
            config = {
              proxyPath = "/";
              maxBodySize = "10m";
            };

            deps.backend = ref.tutorial-09.backend;
          };
          # endregion:configuredGateway
        };
      }
    )
  ];
}
