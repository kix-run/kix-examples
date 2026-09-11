# how-to-package-cilium: install Cilium as the cluster CNI and policy enforcer.
#
# Recommended reading: 12-flavors-capabilities-and-platform-app-boundaries.
#
# What's new: replace a flavor-provided role with a Kix-managed package.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-cilium";
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      # region:ciliumRoleAndPolicy
      # The Kind cluster for this example is created without kindnet, so the
      # CNI role is available for a managed package.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };

      networkPolicy.enable = true;
      # endregion:ciliumRoleAndPolicy

      # region:ciliumInstance
      instances.kube-system.cilium = {
        package = packages.cilium;
        config.values = {
          # Keep Kind's kube-proxy and use the pod CIDR from kind-cilium.yaml.
          kubeProxyReplacement = false;
          ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];

          prometheus.enabled = false;
        };
      };
      # endregion:ciliumInstance
    }
  ];
}
