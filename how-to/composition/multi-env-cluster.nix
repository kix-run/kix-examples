# how-to-multi-env: one application definition stamped into two environments.
#
# Recommended reading: how-to/composition (cluster-wide settings).
#
# What's new: mkEnv prefixes namespaces and applies environment configuration.

{ kix, packages, ... }:

let
  # region:environmentInstanceSet
  application =
    { env, ... }:
    {
      web = {
        package = packages.echo-server;
        config = {
          message = "Hello from ${env.name}";
          replicas = env.config.replicas;
        };
      };
    };
  # endregion:environmentInstanceSet
in
kix.buildCluster {
  name = "how-to-multi-env";

  modules = [
    kix.flavors.kind
    {
      # region:stampEnvironments
      instances =
        kix.mkEnv "development" {
          config.replicas = 1;
        } { app = application; }
        // kix.mkEnv "production" {
          config.replicas = 3;
          overrides.app.web.config.message = "Production storefront";
        } { app = application; };
      # endregion:stampEnvironments
    }
  ];
}
