# reverse-proxy-package.nix — nginx reverse-proxy in front of a `backend`
# dep.
#
# This file is a Kix *package*: an attrset with `meta` and `build`. It's
# imported by cluster.nix and instantiated there as an `instance` named
# `gateway`. Real packages in kixpkgs use the same shape.
#
# Unchanged from 06-service-dep. See that example for the package
# walkthrough; 08's new idea is the explicit cross-namespace `ref` in
# cluster.nix.

{
  meta = {
    version = "0.0.1";
    description = "nginx reverse-proxy in front of a backend Service";
  };

  # The build function is called once per instance, by Kix. It receives
  # a handful of named args:
  #
  #   self    — fixpoint over this package's own resources. Lets you
  #             write `self.configmap.out.name` so the Deployment can
  #             reference the ConfigMap built in the same package.
  #
  #   scope   — per-instance context provided by Kix. Carries the
  #             instance name, target namespace, selector labels, plus
  #             helpers (`mkResource`, `mkDeployment`, ...) that stamp
  #             Kix machinery onto raw K8s manifests.
  #
  #   kix     — the Kix stdlib. Helpers like `kix.port` and
  #             `kix.service.fromWorkload`.
  #
  #   backend — a *dep*. The cluster wires it to a specific instance
  #             (see cluster.nix). Inside the package it appears as an
  #             `out` API: `backend.out.fqdn`, `backend.out.port`, ...
  build =
    {
      self,
      scope,
      kix,
      backend,
      ...
    }:
    let
      # Convention: name resources after the instance they belong to.
      # Here `scope.instanceName` is "gateway" (set in cluster.nix).
      name = scope.instanceName;
    in
    {
      # ConfigMap with nginx.conf.
      #
      # `scope.mkResource` wraps a plain K8s manifest attrset. It
      # stamps the namespace, adds Kix-managed labels and annotations,
      # and exposes the `out` API (`out.name`, `out.fqdn`, ...) for
      # downstream consumers.
      #
      # The interpolation `${backend.out.fqdn}` looks like a normal
      # string substitution. It also carries Nix string context, which
      # Kix uses to stamp a `kix.dev/depends-on` annotation onto this
      # ConfigMap — that's how the deploy DAG learns the backend must
      # be applied first.
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

      # Deployment.
      #
      # `scope.mkDeployment` is like `mkResource` but specialised for
      # workloads: it fills in standard labels and selector matching
      # automatically. `scope.selectorLabels` is the pre-baked label
      # set for this instance, so the Service below can reuse it
      # without manual coordination.
      #
      # `|> scope.mkDeployment` is the Nix pipe operator — the same as
      # `scope.mkDeployment { ... }`, read left-to-right. (Requires the
      # `pipe-operators` experimental feature in your Nix config.)
      #
      # `self.configmap.out.name` reaches *back* into this same
      # package's ConfigMap and reads its real K8s name. Going via
      # `.out.name` rather than hardcoding the string means the
      # Deployment carries a Kix dep edge on the ConfigMap, so a rebuilt
      # ConfigMap forces a Deployment rollout.
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
                  # `kix.port "http" 80` is shorthand for
                  # `{ name = "http"; containerPort = 80; }`.
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

      # Service.
      #
      # `kix.service.fromWorkload` derives a Service manifest from a
      # workload: the selector and ports come from the Deployment so
      # they can't drift out of sync. We then run the result through
      # `scope.mkResource` to wrap it like any other Kix resource.
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

      # Root.
      #
      # `root` is a convention: it's the "main" resource of this
      # package — what other packages get when they reference *this*
      # instance through `<thisInstance>.out.<x>`. For a service-shaped
      # package the Service is the natural root, since that's what
      # other workloads talk to.
      root = self.service;
    };
}
