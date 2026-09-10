# how-to-platform-secrets: managed and externally managed Secret references.
#
# Recommended reading: 06-service-dep (package resources and out values).
#
# What's new: secret builders validate keys and preserve deploy ordering.

{ kix, ... }:

let
  managedSecretApp = import ./managed-secret-app.nix;
  externalSecretApp = import ./external-secret-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-secrets";

  modules = [
    kix.flavors.kind
    {
      namespaces.secret-examples = { };

      instances.secret-examples = {
        managed-example.package = managedSecretApp;
        external-example.package = externalSecretApp;
      };
    }
  ];
}
