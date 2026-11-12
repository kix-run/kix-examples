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
      # Keeps Kind's kube-proxy; the IPAM pool is the kind flavour's
      # cluster.network.podCidr, the podSubnet in kind-cilium.yaml.
      instances.kube-system.cilium = {
        package = packages.experimental.cilium;
      };
      # endregion:ciliumInstance
    }
  ];
}
