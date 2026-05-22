# 03-cross-namespace — wiring a dep across a namespace boundary.
#
# Same idea as 02 (a gateway proxying to a backend) but the two
# instances now live in different namespaces:
#
#   platform — owns `backend` (an echo-server)
#   app      — owns `gateway` (the reverse-proxy)
#
# Because they're in separate namespaces, name-matching alone wouldn't
# find a `backend` for the gateway from inside the `app` namespace, so
# we wire the dep out explicitly using `ref`:
#
#   deps.backend = ref.platform.backend;
#
# That's the same `ref` introduced (but unused) in 02. Here it earns
# its keep.
#
# Kix actually *would* find `backend` cluster-wide via its
# other-namespace fallback (see kix/lib/architecture.md on the
# resolver). We're not relying on that — the example is about being
# explicit when crossing a boundary. See kixpkgs issue #19 for the
# discussion on making cross-namespace resolution opt-in.

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
        # other shared infrastructure tend to live in their own
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
