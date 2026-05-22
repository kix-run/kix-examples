# 02-service-dep — one service talking to another.
#
# Two instances in an `example-02` namespace:
#
#   backend  — an echo-server (existing package in kixpkgs). Just
#              answers HTTP requests with a fixed message.
#
#   gateway  — an instance of the local reverse-proxy package (defined
#              in ./reverse-proxy-package.nix). Its build function asks
#              for a `backend` dep — and Kix wires it to the instance
#              named `backend` above, automatically, by name.
#
# When you `kix pf` the gateway and curl it, the request goes:
#
#   localhost:8080  →  gateway pod  →  backend Service  →  backend pod
#
# That round trip is what proves the wiring is real: no compile-time
# string interpolation could fake an actual cluster-DNS lookup.

{ kix, packages }:

# `let ... in expr` is Nix's local-binding syntax (think `let` in JS).
# Here we import our local package once and bind it to a name we'll
# reuse below.
let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "02-service-dep";

  modules = [
    kix.flavors.kind

    # A module written as a function. `{ ref, ... }:` destructures
    # the args Kix passes in — we accept `ref` (you'll see it used
    # in 03) and `...` means "ignore any other named args".
    (
      { ref, ... }:
      {
        namespaces = {
          example-02 = { };
        };

        instances.example-02 = {
          # Backend: a plain echo-server. Named `backend` because the
          # gateway's package (see ./reverse-proxy-package.nix) takes an
          # arg called `backend` — Kix matches the two up by name.
          backend = {
            package = packages.echo-server;
            config = {
              message = "Hello from the backend!";
            };
          };

          # Gateway: nginx proxying to `backend`. Nothing here references
          # the backend explicitly — the package itself declares the need
          # for a `backend` instance, which Kix resolves to the instance
          # above.
          #
          # If you'd rather make the wiring explicit, write it out
          # explicitly using `ref`:
          #
          #   gateway = {
          #     package = reverseProxyPackage;
          #     deps.backend = ref.example-02.backend;
          #   };
          gateway = {
            package = reverseProxyPackage;
          };
        };
      }
    )
  ];
}
