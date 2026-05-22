# 03-cross-namespace — wiring a dep across a namespace boundary.
#
# Same idea as 02 (a gateway proxying to a backend) but the two
# instances now live in different namespaces:
#
#   platform — owns `backend` (an echo-server)
#   app      — owns `gateway` (the reverse-proxy)
#
# Because they're in separate namespaces, we write the dependency
# explicitly using `ref`:
#
#   deps.backend = ref.platform.backend;
#
# That's the same `ref` introduced in 02. Here we use it to point at
# one exact instance outside the gateway's namespace.
#
# Kix currently has an other-namespace fallback resolver, so this would
# still work without `deps.backend`. This example writes the dependency
# anyway because namespace boundaries are easier to review when they are
# visible at the call site. See kixpkgs issue #19 for the discussion on
# making cross-namespace resolution opt-in.
#
# Recommended reading: 02-service-dep.
#
# What's new: `deps.backend = ref.platform.backend`, which wires a dep
# across namespaces instead of relying on same-namespace name matching.

{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "03-cross-namespace";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        namespaces = {
          platform = { };
          app = { };
        };

        # Platform-owned services. Things like databases, caches, and
        # other shared infrastructure may live in their own
        # namespace so application teams don't accidentally collide
        # with them.
        instances.platform = {
          backend = {
            package = packages.echo-server;
            config = {
              message = "Hello from the platform-owned backend!";
            };
          };
        };

        # Application-owned services. The gateway reaches across into
        # `platform` for its backend.
        instances.app = {
          gateway = {
            package = reverseProxyPackage;
            # Explicit cross-namespace wiring. Without this line,
            # Kix's resolver would still find `backend` in `platform`
            # (the cluster-wide fallback), but writing it out makes
            # the boundary crossing visible at the call site.
            deps.backend = ref.platform.backend;
          };
        };
      }
    )
  ];
}
