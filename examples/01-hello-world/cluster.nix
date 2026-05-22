# 01-hello-world — the smallest possible Kix cluster.
#
# One echo-server in an `example-01` namespace. No dependencies, no
# secrets, and no local packages yet. This is just enough to prove the
# Kix loop works:
#
#   edit cluster.nix -> nix build -> kubectl apply -> see the change.
#
# Recommended reading: none. This is the first example.
#
# What's new: the basic shape of a Kix cluster — flavor, namespaces,
# and instances.
#
# New to Nix? The root README has a glossary covering every Nix
# construct used in these examples. Keep it nearby while you read.

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
    # Sets the Kix flavor. These examples use kind (Kubernetes in Docker).
    # Setting the flavor allows Kix to assume sensible defaults.
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
