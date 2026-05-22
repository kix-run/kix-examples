# 04-typed-options — typed package config via `lib.mkOption`.
#
# Recommended reading: 02-service-dep (packages + deps),
# 03-cross-namespace (`ref`). This file assumes you know what
# `package`, `config`, `deps`, and `ref` mean.
#
# What's new: the gateway's `config` block now has typed knobs
# (`proxyPath`, `maxBodySize`) declared and validated by the package
# in ./reverse-proxy-package.nix. Misconfigure them and you get an
# error from `nix build`, not a 5xx in production.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "04-typed-options";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        namespaces = {
          example-04 = { };
        };

        instances.example-04 = {
          backend = {
            package = packages.echo-server;
            config = {
              message = "Hello from the backend!";
            };
          };

          gateway = {
            package = reverseProxyPackage;

            # Both options are typed in the package. Try giving
            # `proxyPath` a value that doesn't start with `/`, or
            # `maxBodySize` something like "1mb" (wrong suffix), and
            # the build will fail with a type error.
            config = {
              proxyPath = "/";
              maxBodySize = "10m";
            };

            deps.backend = ref.example-04.backend;
          };
        };
      }
    )
  ];
}
