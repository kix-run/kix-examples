# reverse-proxy-package.nix — nginx reverse-proxy with typed options.
#
# Unchanged from 04-typed-options. The interesting bit of 06 is in
# ./scorecard.nix, not here. See 04 for the walkthrough of the
# package shape and the typed options.

{ scope, lib, kix }:

{
  meta = {
    version = "0.0.2";
    description = "nginx reverse-proxy with typed config options";
  };

  options = {
    proxyPath = lib.mkOption {
      # `lib.types.strMatching` runs the regex at module-merge time;
      # if `proxyPath = "api"` (no leading slash) is set, you get a
      # type error from the cluster build, not a nginx 404 at runtime.
      type = lib.types.strMatching "^/.*$";
      default = "/";
      description = "URL path this proxy forwards. Must start with `/`.";
      example = "/api/";
    };

    maxBodySize = lib.mkOption {
      # nginx body-size format: number with optional k/K/m/M/g/G suffix.
      type = lib.types.strMatching "^[0-9]+[kKmMgG]?$";
      default = "1m";
      description = ''
        Max request body size, in nginx format (e.g. "1m", "100k", "50M").
        Sets `client_max_body_size`.
      '';
      example = "10m";
    };
  };

  build =
    {
      self,
      scope,
      kix,
      backend,
      config,
      ...
    }:
    let
      name = scope.instanceName;
    in
    {
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        inherit name;
        data."default.conf" = ''
          server {
              listen 80;
              client_max_body_size ${config.maxBodySize};

              location /healthz {
                  default_type text/plain;
                  return 200 'ok\n';
              }
              location ${config.proxyPath} {
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
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 80;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
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
