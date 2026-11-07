# 08-namespace-deps — wiring a dep across a namespace boundary.
#
# Same idea as 06 (a gateway proxying to a backend) but the two
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
# That's the same `ref` introduced in 06. Here we use it to point at
# one exact instance outside the gateway's namespace.
#
# Recommended reading: 06-service-dep.
#
# What's new: `deps.backend = ref.platform.backend`, which wires a dep
# across namespaces instead of relying on same-namespace name matching.

# region:clusterFrame
{ kix, packages }:

let
  reverseProxyPackage = import ./reverse-proxy-package.nix;
in
kix.buildCluster {
  name = "08-namespace-deps";

  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        # region:namespacesAndInstances
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
          # region:crossNamespaceDep
          gateway = {
            package = reverseProxyPackage;
            # Explicit cross-namespace wiring keeps the boundary
            # crossing visible at the call site.
            deps.backend = ref.platform.backend;
          };
          # endregion:crossNamespaceDep
        };
        # endregion:namespacesAndInstances
      }
    )
  ];
}
# endregion:clusterFrame
