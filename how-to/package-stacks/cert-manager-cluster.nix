# how-to-package-cert-manager: install cert-manager and configure an issuer.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: connect an issuer package to cert-manager through dependency injection.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-cert-manager";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      # region:certManagerAndIssuer
      instances.cert-manager = {
        cert-manager = {
          package = packages.cert-manager;
        };

        cluster-issuers = {
          package = packages.cluster-issuers;
          config = { lib, ... }: {
            mainIssuer = "local-self-signed";
            issuers = lib.mkForce {
              local-self-signed.kind = "selfSigned";
            };
          };
        };
      };
      # endregion:certManagerAndIssuer
    }
  ];
}
