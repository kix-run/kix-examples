# how-to-package-python: deploy a minimal HTTP service with python-app.
#
# Recommended reading: 09-typed-options (package configuration).
#
# What's new: configure the catalogue's python-app package for one backend.

{ kix, packages, ... }:

kix.buildCluster {
  name = "how-to-package-python";

  modules = [
    kix.flavors.kind
    {
      # region:pythonApplicationInstance
      instances.python-example.web = {
        package = packages."python-app";
        config = {
          environment = "development";
          env.MESSAGE = "Hello from Kix";

          backend = {
            image = {
              repository = "docker.io/library/python";
              tag = "3.13-slim";
              pullPolicy = "IfNotPresent";
            };
            command = [ "python" ];
            args = [ "-m" "http.server" "8080" ];
            port = 8080;
            replicaCount = 1;
            probes.path = "/";
          };
        };
      };
      # endregion:pythonApplicationInstance
    }
  ];
}
