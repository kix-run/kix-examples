# how-to-stateful-after: the target side of a stateful migration pair.

{ kix, ... }:

let
  statefulVolume = import ./stateful-volume-package.nix;
in
kix.buildCluster {
  name = "how-to-stateful-migration";

  modules = [
    kix.flavors.kind
    {
      instances.data.volume = {
        package = statefulVolume;
        config = {
          claimName = "media-v2";
          size = "10Gi";
        };
      };
    }
  ];
}
