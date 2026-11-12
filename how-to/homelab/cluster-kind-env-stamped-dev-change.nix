# homelab-kind-env-stamped-dev-change: change the dev environment only.
#
# The cluster name is `homelab-kind-env`, the same as
# cluster-kind-env-stamped.nix, so a deploy over it is an upgrade.
#
# Changes from cluster-kind-env-stamped.nix:
#   - dev-vaultwarden storage goes from 512Mi to 1Gi.
#   - dev-nas storage goes from 10Gi to 20Gi.
#   - dev hosts move from homelab.lan to homelab-v2.lan.
#   - staging does not change.
#
# A deploy of this cluster should touch only objects in `dev-*`
# namespaces.
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

        instances.ingress-nginx.ingress-nginx = {
          package = packages.experimental."ingress-nginx";
        };

        # Shared database operator, one per cluster (see the base variant:
        # its cluster-scoped resources collide when each env gets a copy).
        instances.stackgres.stackgres-operator = {
          package = packages.experimental."stackgres-operator";
        };

        # The dev environment. Only this environment changes.
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
            config.size = "1Gi"; # was 512Mi
          };
          vaultwarden = {
            package = packages.experimental.vaultwarden;
            config.ingress.host = "vault-dev.homelab-v2.lan"; # was homelab.lan
          };
        };

        instances."dev-nas" = {
          storage = {
            package = packages."persistent-volume-claim";
            config.size = "20Gi"; # was 10Gi
          };
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files-dev.homelab-v2.lan"; # was homelab.lan
          };
        };

        # The staging environment, unchanged.
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
