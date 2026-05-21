# 01-hello — the smallest possible Kix cluster.
#
# One echo-server in an `example-01` namespace. No dependencies, no
# secrets, nothing fancy. Just enough to prove the Kix loop works:
#
#   edit cluster.nix -> nix build -> kubectl apply -> see the change.

{ kix, packages }:

kix.buildCluster {
  name = "01-hello";

  modules = [
    # Sets the kind flavour: kindnet CNI, ephemeral storage, no LoadBalancer.
    kix.flavors.kind

    {
      namespaces = {
        example-01 = { };
      };

      instances.example-01 = {
        hello = {
          package = packages.echo-server;
          config = {
            message = "Hello from Kix!";
          };
        };
      };
    }
  ];
}
