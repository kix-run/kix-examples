# homelab-kind-env-stamped: two environments on one cluster.
#
# The cluster name is `homelab-kind-env`. This is a separate cluster, not
# an upgrade of `homelab-kind`.
#
# The same services (Vaultwarden and File Browser) are deployed twice:
#   - in `dev-*` namespaces, with small volumes
#   - in `staging-*` namespaces, with larger volumes and other hosts
#
# Each environment gets its own namespaces, claims, Ingresses and network
# policies, and no instance depends on an instance in the other
# environment. cluster-kind-env-stamped-dev-change.nix changes only dev,
# and the demo checks that no staging object changes.
#
# The light services keep the demo fast. The full homelab stack would work
# the same way.
#
# Demo: demos/demo-env-stamped.sh

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind-env";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    ./platform.nix

    (
      { lib, ... }:
      {
        # Settings both environments share.
        cluster.domain = "homelab.lan";
        availablePackages = packages;
        clusterLabels = {
          "app.kubernetes.io/part-of" = "homelab";
          "cluster" = "homelab-env";
        };

        # The deploy scripts create kind with disableDefaultCNI, so the cni role
        # is vacant; the managed cilium instance fills it.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        instances.kube-system.cilium = {
          package = packages.experimental.cilium;
        };

        # Both environments route through the same ingress-nginx.
        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };

        # Shared database operator, one per cluster. Its ClusterRoleBinding
        # and webhook configurations are cluster-scoped under one name, so
        # the per-env copies that auto-instantiation used to create in each
        # vaultwarden namespace collided: the manifest writer kept one and
        # the other env's operator pointed at the wrong ServiceAccount. The
        # duplicate-identity check now refuses that build.
        instances.stackgres.stackgres-operator = {
          package = packages.experimental."stackgres-operator";
        };

        # The dev environment.
        # Small storage, dev domain, minimal footprint.
        instances."dev-vaultwarden" = {
          # StackGres and CloudNativePG both answer `postgres`; this
          # optional instance picks StackGres for the database below.
          stackgres-cluster = {
            package = packages.experimental.stackgres-cluster;
            optional = true;
          };
          # The password comes from a SOPS file encrypted to the test-only key.
          vaultwarden-db = {
            package = packages.experimental.stackgres-database;
          };
          vaultwarden-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./secrets/dev-vaultwarden-db.sops.yaml;
              hash = "sha256-6z8/KT0AyFm5bcHSAUTHDPtaVgTnuIfnTOC9r6MFxng=";
              keys = [ "password" ];
            };
          };
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "512Mi";
          };
          vaultwarden = {
            package = packages.experimental.vaultwarden;
            config.ingress.host = "vault-dev.homelab.lan";
          };
        };

        instances."dev-nas" = {
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "10Gi";
          };
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files-dev.homelab.lan";
          };
        };

        # The staging environment.
        # Larger storage, staging domain, production-shaped config.
        instances."staging-vaultwarden" = {
          # StackGres and CloudNativePG both answer `postgres`; this
          # optional instance picks StackGres for the database below.
          stackgres-cluster = {
            package = packages.experimental.stackgres-cluster;
            optional = true;
          };
          # The password comes from a SOPS file encrypted to the test-only key.
          vaultwarden-db = {
            package = packages.experimental.stackgres-database;
          };
          vaultwarden-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./secrets/staging-vaultwarden-db.sops.yaml;
              hash = "sha256-S/koUrFO5P3Yx4kHCQ0jQrSCnf7KxVEN2nfQnAbCX/o=";
              keys = [ "password" ];
            };
          };
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "2Gi";
          };
          vaultwarden = {
            package = packages.experimental.vaultwarden;
            config.ingress.host = "vault-staging.homelab.lan";
          };
        };

        instances."staging-nas" = {
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "50Gi";
          };
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files-staging.homelab.lan";
          };
        };
      }
    )
  ];
}
