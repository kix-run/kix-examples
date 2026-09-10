# storefront-fragment.nix: application-team contribution to the same cluster.

{ packages }:

{
  # region:storefrontFragment
  namespaces.apps.labels."app.kubernetes.io/part-of" = "storefront";

  instances.apps.storefront = {
    package = packages.echo-server;
    config.message = "Storefront ready";
  };
  # endregion:storefrontFragment
}
