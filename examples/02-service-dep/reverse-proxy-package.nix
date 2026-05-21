# reverse-proxy-package.nix — nginx reverse-proxy in front of a
# `backend` dep.
#
# Shaped exactly like a real Kix package (see kix/packages/echo-server in
# kixpkgs): an attrset with `meta` + `build`, where `build` declares the
# deps it needs as named args. Imported from cluster.nix via:
#
#   let reverseProxyPackage = import ./reverse-proxy-package.nix; in ...
#
# Note the separation: this file is the *package* (named for what it is,
# a reverse-proxy). The cluster instantiates it as an instance called
# `gateway` (named for the role it plays). Kix keeps those concepts
# distinct — one package can back many instances.
#
# This is what a local-to-this-repo package looks like today. Kix has
# no built-in extension point for adding extra packages to mkFlake's
# catalog, so we just import the file directly.

{
  meta = {
    version = "0.0.1";
    description = "nginx reverse-proxy in front of a backend Service";
  };

  build =
    {
      self,
      scope,
      kix,
      backend,
      ...
    }:
    let
      name = scope.instanceName;
    in
    {
      # nginx.conf — proxies / to the backend's in-cluster DNS name.
      # The FQDN and port both come from the dep, not from hardcoded
      # strings. Kix also threads the dep through string context, so
      # this ConfigMap ends up with a `kix.dev/depends-on` edge to
      # the backend.
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        inherit name;
        data."default.conf" = ''
          server {
              listen 80;
              location /healthz {
                  default_type text/plain;
                  return 200 'ok\n';
              }
              location / {
                  proxy_pass http://${backend.out.fqdn}:${backend.out.port}/;
              }
          }
        '';
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              containers = [
                {
                  name = "nginx";
                  image = "nginx:1.27-alpine";
                  imagePullPolicy = "IfNotPresent";
                  ports = [ (kix.port "http" 80) ];
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 80;
                    };
                    periodSeconds = 5;
                  };
                  volumeMounts = [
                    {
                      name = "config";
                      mountPath = "/etc/nginx/conf.d";
                      readOnly = true;
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "config";
                  configMap.name = self.configmap.out.name;
                }
              ];
            };
          };
        }
        |> scope.mkDeployment;

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          ports = [
            {
              name = "http";
              port = 80;
              targetPort = "http";
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      root = self.service;
    };
}
