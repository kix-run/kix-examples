# how-to-platform-sops: a workload backed by a SOPS-encrypted Secret.
#
# Recommended reading: 16-secrets (managed Secrets and their out helpers).
#
# What's new: Kix decrypts Secret values during deployment, not evaluation.

{ kix, ... }:

let
  sopsSecretApp = import ./sops-secret-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-sops";

  modules = [
    kix.flavors.kind
    {
      instances.sops-example.app.package = sopsSecretApp;
    }
  ];
}
