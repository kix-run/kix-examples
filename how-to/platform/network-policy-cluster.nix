# how-to-platform-network-policy: derive policy from a Service dependency.
#
# Recommended reading: 08-namespace-deps and the Cilium installation how-to.
#
# What's new: enable default-deny and generate the allowances required by the
# application dependency graph.

{ kix, packages, ... }:

let
  clientPackage = import ./network-policy-client.nix;
in
kix.buildCluster {
  name = "how-to-platform-network-policy";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };

        # region:networkPolicySettings
        networkPolicy = {
          enable = true;
          defaultDeny = true;
          directions = "both";
        };
        # endregion:networkPolicySettings

        # region:externalWorkloadIntent
        networkPolicy.platformIntents.metrics-agent = {
          scope = "clusterwide";
          targetNamespace = "observability";
          podSelector."app.kubernetes.io/name" = "metrics-agent";
          egress = [
            { to = "dns"; }
            {
              to = "world";
              ports = [
                {
                  port = 443;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };
        # endregion:externalWorkloadIntent

        instances.kube-system.cilium = {
          package = packages.experimental.cilium;
        };

        # region:networkPolicyInstances
        instances.services.backend = {
          package = packages.echo-server;
          config.message = "Hello across a generated network policy!";
        };

        instances.apps.client = {
          package = clientPackage;
          deps.backend = ref.services.backend;
        };
        # endregion:networkPolicyInstances
      }
    )
  ];
}
