# 01-hello-world — the smallest possible Kix cluster.
#
# One echo-server in an `example-01` namespace. No dependencies, no
# secrets, nothing fancy. Just enough to prove the Kix loop works:
#
#   edit cluster.nix -> nix build -> kubectl apply -> see the change.
#
# New to Nix? The root README has a glossary covering every Nix
# construct used in these examples — open it in a second tab and
# refer back whenever the syntax surprises you.

# Nix functions take their args as an attrset. This file is a function
# that Kix calls with `kix` (the framework) and `packages` (the
# package catalog from kixpkgs).
{ kix, packages }:

# `kix.buildCluster` builds a cluster spec from an attrset. The body
# below is one big attrset literal.
kix.buildCluster {
  name = "01-hello-world";

  # `modules` is a list (whitespace-separated, no commas).
  modules = [
    # Sets the kix flavour. These examples use kind (Kubernetes in Docker).
    # Setting the flavour allows Kix to assume sensible defaults.
    kix.flavors.kind

    # A module — an attrset describing part of the cluster.
    {
      # Every namespace the cluster manages. `{ }` is an empty attrset
      # — we don't need any per-namespace config here.
      namespaces = {
        example-01 = { };
      };

      # `instances.<namespace> =` is the dotted-path shorthand for
      # creating a nested attrset.
      # Here we have an instance named `hello-world` in namespace
      # `example-01`.
      instances.example-01 = {
        hello-world = {
          # `packages.echo-server` ships in the public kixpkgs
          # repository, along with many others.
          # It serves a simple fixed message over HTTP.
          package = packages.echo-server;

          # `config` is whatever the package's options accept.
          # echo-server's `message` becomes the body of every response.
          config = {
            message = "Hello from Kix!";
          };
        };
      };
    }
  ];
}
