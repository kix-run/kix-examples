# how-to-helm-bridge: render an upstream Helm chart through Kix.
#
# Recommended reading: 13-imports-and-existing-cluster-resources.
#
# What's new: use an upstream chart as a Kix package instance.

{ kix, ... }:

kix.buildCluster {
  name = "how-to-helm-bridge";

  modules = [
    kix.flavors.kind
    {
      # region:inlineHelmChart
      instances.reflector-system.reflector = {
        package = kix.helmChart {
          repo = "https://emberstack.github.io/helm-charts";
          name = "reflector";
          version = "10.0.60";
          hash = "sha256-UdCVcUqJogyUYmGo1HnQ1fMxY7ZEV56+9wQSJfWOhVM=";
          releaseName = "reflector";
        };
      };
      # endregion:inlineHelmChart
    }
  ];
}
