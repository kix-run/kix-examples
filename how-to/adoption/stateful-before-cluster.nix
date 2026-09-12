# how-to-stateful-before: the source side of a stateful migration pair.

{ kix, ... }:

let
  statefulVolume = import ./stateful-volume-package.nix;
in
kix.buildCluster {
  name = "how-to-stateful-before";

  modules = [
    kix.flavors.kind
    {
      instances.data.volume = {
        package = statefulVolume;
        config = {
          claimName = "media-v1";
          size = "5Gi";
        };
      };
    }
  ];
}
