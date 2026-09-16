# how-to-platform-hostpath: mount a node-local directory into a workload.
#
# Recommended reading: 06-service-dep (local packages and instances).
#
# What's new: a workload uses a hostPath mount on a compatible cluster.

{ kix, ... }:

let
  hostPathApp = import ./hostpath-app.nix;
in
kix.buildCluster {
  name = "how-to-platform-hostpath";

  modules = [
    kix.flavors.kind
    {
      # region:hostPathApplicationInstance
      instances.hostpath-example.worker = {
        package = hostPathApp;
      };
      # endregion:hostPathApplicationInstance
    }
  ];
}
