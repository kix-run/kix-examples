{ kix, packages }:

# Finished version of the cluster the docs ask you to build in
# tutorials/04-first-cluster-from-scratch/. The docs pipeline captures
# `kix check`, `kix build`, and `kix graph` output against this so the
# rendered shape matches what the reader will see when they finish the
# tutorial.

kix.buildCluster {
  name = "04-from-scratch";

  modules = [
    kix.flavors.kind

    {
      namespaces = {
        tutorial-04 = { };
      };

      instances.tutorial-04 = {
        hello-world = {
          package = packages.echo-server;
          config = {
            message = "Hello from my first Kix cluster!";
          };
        };
      };
    }
  ];
}
