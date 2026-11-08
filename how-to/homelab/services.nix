# Services: all application workloads.
# Hosts auto-derive from cluster.domain (e.g. immich.homelab.lan).
# Override with config.ingress.host if a different subdomain is needed.
#
# This cluster uses Gateway API. Packages using kix.expose get HTTPRoutes
# automatically, with no per-app ingress controller wiring.
# LAN-only: plain HTTP, no TLS.

{
  config,
  packages,
  kix,
  lib,
  ref,
  ...
}:
let
  domain = config.cluster.domain;
  features = config.homelab.features;
in
{
  # Each app group is gated behind `homelab.features.<name>` (see
  # platform.nix). Shared data infra (StackGres Postgres) is always on.
  # The passwords are literals because these clusters are for local
  # testing. A real deployment points each secret at a SOPS file.
  config.instances = lib.mkMerge [

    # --- Shared Postgres (StackGres), always on ---
    {
      data.postgres = {
        package = packages.stackgres-cluster;
        aliases = [ "postgres" ];
        config = {
          instances = 1;
          postgres.version = "16";
          # Extensions are forwarded automatically from each consuming
          # stackgres-database instance via dep config injection. Immich
          # declares its required set (vchord, uuid-ossp, cube,
          # earthdistance, unaccent, pg_trgm) on its database, which
          # propagates up to this cluster. Only declare extensions here
          # if the cluster needs something no consumer app asks for.
          persistentVolume.size = "50Gi";
          instanceProfile = {
            cpu = "2";
            memory = "2Gi";
          };
        };
      };
    }

    # --- Immich: photo backup & sharing (+ Valkey + per-app DB) ---
    (lib.mkIf features.immich {
      # Standalone on one node: Sentinel follows the availability level and
      # turns on from "node" up, when the cluster spans several nodes.
      immich.valkey.package = packages.valkey;

      immich.valkey-password = {
        package = packages.secret;
        aliases = [ "valkeyPassword" ];
        config = {
          keys = [ "password" ];
          stringData.password = "dev-password";
        };
      };

      # Per-app database + role on the shared `data.postgres` StackGres cluster.
      # Provides the `database` alias immich depends on; the extensions immich
      # adds to it (vchord and others) are forwarded to the postgres backend.
      immich.immich-db = {
        package = packages.stackgres-database;
        aliases = [ "database" ];
        deps.postgres = ref.data.postgres;
        config = {
          database = "immich";
          user = "immich";
          password = "immich-dev-password";
        };
      };

      immich.storage = {
        package = packages."persistent-volume-claim";
        config.size = "100Gi"; # expand when on ZFS
      };

      immich.immich.package = packages.immich;
    })

    # --- NAS: file browsing ---
    # guest sees only /guest.
    (lib.mkIf features.nas {
      nas.storage = {
        package = packages."persistent-volume-claim";
        config.size = "200Gi";
      };

      nas.filebrowser-users = {
        package = packages.secret;
        aliases = [ "filebrowserUsers" ];
        config = {
          keys = [
            "admin"
            "guest"
          ];
          stringData = {
            admin = "admin-dev-password";
            guest = "guest-dev-password";
          };
        };
      };

      nas.filebrowser = {
        package = packages.filebrowser;
        config = {
          ingress.host = "files.${domain}"; # override: "filebrowser" is too long
          # A multi-hour upload over a home connection outlasts the 2h default.
          tokenExpirationTime = "24h";
          users = {
            admin.admin = true;
            guest = {
              scope = "/guest";
              perm.share = false;
            };
          };
        };
      };
    })

    # --- Vaultwarden: password management (+ per-app DB) ---
    (lib.mkIf features.vaultwarden {
      vaultwarden.storage = {
        package = packages."persistent-volume-claim";
        config.size = "1Gi";
      };

      # A literal password; a deployment with real users sets
      # passwordSource and passwordHash instead.
      vaultwarden.vaultwarden-db = {
        package = packages.stackgres-database;
        deps.postgres = ref.data.postgres;
        config = {
          database = "vaultwarden";
          user = "vaultwarden";
          password = "vaultwarden-dev-password";
        };
      };

      vaultwarden.vaultwarden = {
        package = packages.vaultwarden;
        # ingress.host defaults to vaultwarden.<domain> ✓
      };
    })

    # --- HomeAssistant: home automation ---
    # NOTE: Helm chart creates its own Ingress resource via values.
    # On this cluster we disable the Helm-managed Ingress and let
    # the chart just run the app. Exposure is handled by a manual
    # HTTPRoute wired to the gateway.
    (lib.mkIf features.homeassistant {
      homeassistant.homeassistant = {
        package = kix.helmChart {
          repo = "https://pajikos.github.io/home-assistant-helm-chart";
          name = "home-assistant";
          version = "0.3.51";
          hash = "sha256-gcZzrAYS23YiOyVJg8cIntyBQmF/Q+/d0q5sKWtl8WY=";
          releaseName = "homeassistant";
          patchResources = map (
            r:
            if r.kind == "Service" && r.metadata.name == "homeassistant-home-assistant" then
              r
              // {
                spec = r.spec // {
                  clusterIP = "None";
                };
              }
            else
              r
          );
        };
        config.values = {
          ingress.enabled = false;
          persistence = {
            enabled = true;
            size = "5Gi";
          };
        };
      };
    })

  ];
}
