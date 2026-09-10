# how-to-fragments: one cluster assembled from team-owned fragments.
#
# Recommended reading: how-to/composition (cluster-wide settings).
#
# What's new: mergeFragments combines separate namespace and instance trees.

{ kix, packages, ... }:

let
  platformFragment = import ./platform-fragment.nix { inherit packages; };
  storefrontFragment = import ./storefront-fragment.nix { inherit packages; };

  # region:mergeTeamFragments
  composition = kix.mergeFragments {
    fragments = [
      platformFragment
      storefrontFragment
    ];

    # Policies applied by the cluster owner merge with the team fragments.
    namespacePolicies.apps.labels."platform.example.com/managed" = "true";
  };
  # endregion:mergeTeamFragments
in
kix.buildCluster {
  name = "how-to-fragments";

  modules = [
    kix.flavors.kind
    {
      # region:useMergedFragments
      namespaces = composition.namespaces;
      instances = composition.instances { };
      # endregion:useMergedFragments
    }
  ];
}
