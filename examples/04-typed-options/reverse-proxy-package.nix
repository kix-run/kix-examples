# reverse-proxy-package.nix — nginx reverse-proxy with typed options.
#
# Recommended reading: 02-service-dep (which introduced the package
# shape: attrset with `meta` + `build`, deps as named build args).
#
# What's new: this version is a *function* `{ scope, lib, kix }: { ... }`
# so it can declare typed `options` using `lib.mkOption` / `lib.types`.
# Kix auto-discovers which args we want and passes them in.
#
# Two new knobs vs 02/03:
#
#   proxyPath       — path the proxy forwards. Type forces it to start
#                     with `/`, so a typo like `api` (instead of `/api`)
#                     fails at build time, not at request time.
#
#   maxBodySize     — nginx `client_max_body_size`. nginx defaults to
#                     1 MB silently, which has burned more file-upload
#                     features than any of us care to admit. Making it
#                     explicit (with a typed format) is a low-cost win.

{ scope, lib, kix }:

{
  meta = {
    version = "0.0.2";
    description = "nginx reverse-proxy with typed config options";
  };

  # `options` declares the package's config surface. Each option is
  # built with `lib.mkOption` (a nixpkgs helper) and has a `type`, a
  # `default`, a `description`, and optionally an `example`. Whatever
  # the cluster passes in `config = { ... }` is checked against these
  # types before any K8s manifest gets rendered.
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
