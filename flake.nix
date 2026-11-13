# region:exampleFlake
{
  description = "Kix example clusters — a tour of Kix patterns runnable on kind.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # The Kix library. Kix reads the tag below from flake.lock and runs
    # exactly that version of Kix, so `kix upgrade --to <version>` is how
    # this moves. While kix-run/kix is private, fetching it needs a GitHub
    # token in nix.conf (`access-tokens = github.com=...`). The Kix docs
    # captures override this input with the Kix checkout they build.
    kix.url = "github:kix-run/kix/v0.10.0-rc.3";
    kix.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Each example folder has its own cluster.nix. Add a new example by
  # appending a line here and creating examples/NN-name/cluster.nix.
  # region:mkFlakeOutputs
  outputs =
    inputs:
    inputs.kix.lib.mkFlake {
      inherit inputs;
      clusters = {
        "02-hello-world" = ./tutorials/02-hello-world/cluster.nix;
        "06-service-dep" = ./tutorials/06-service-dep/cluster.nix;
        "08-namespace-deps" = ./tutorials/08-namespace-deps/cluster.nix;
        "09-typed-options" = ./tutorials/09-typed-options/cluster.nix;
        "10-reuse-packages" = ./tutorials/10-reuse-packages/cluster.nix;
        "19-scorecards" = ./tutorials/19-scorecards/cluster.nix;
        "how-to-application" = ./how-to/application/cluster.nix;
        "how-to-adoption" = ./how-to/adoption/cluster.nix;
        "how-to-stateful-migration" = ./how-to/adoption/stateful-before-cluster.nix;
        "how-to-adoption-takeover" = ./how-to/adoption/takeover-cluster.nix;
        "how-to-helm-bridge" = ./how-to/adoption/helm-bridge-cluster.nix;
        "how-to-auto-instantiation" = ./how-to/auto-instantiation/cluster.nix;
        "how-to-composition" = ./how-to/composition/cluster.nix;
        "how-to-fragments" = ./how-to/composition/fragments-cluster.nix;
        "how-to-multi-env" = ./how-to/composition/multi-env-cluster.nix;
        "how-to-package-storage" = ./how-to/package-stacks/storage-cluster.nix;
        "how-to-package-stackgres" = ./how-to/package-stacks/stackgres-cluster.nix;
        "how-to-package-monitoring" = ./how-to/package-stacks/monitoring-cluster.nix;
        "how-to-package-monitoring-loki" = ./how-to/package-stacks/monitoring-loki-cluster.nix;
        "how-to-package-cilium" = ./how-to/package-stacks/cilium-cluster.nix;
        "how-to-package-valkey" = ./how-to/package-stacks/valkey-cluster.nix;
        "how-to-package-velero" = ./how-to/package-stacks/velero-cluster.nix;
        "how-to-package-victoria-metrics" = ./how-to/package-stacks/victoria-metrics-cluster.nix;
        "how-to-platform-gateway" = ./how-to/platform/gateway-cluster.nix;
        "how-to-platform-hostpath" = ./how-to/platform/hostpath-cluster.nix;
        "how-to-platform-ingress" = ./how-to/platform/ingress-cluster.nix;
        "how-to-platform-monitoring" = ./how-to/platform/monitoring-cluster.nix;
        "how-to-platform-network-policy" = ./how-to/platform/network-policy-cluster.nix;
        "how-to-platform-secrets" = ./how-to/platform/secrets-cluster.nix;
        "how-to-platform-sops" = ./how-to/platform/sops-secrets-cluster.nix;
        "how-to-platform-cloudflare-tunnel" = ./how-to/platform/cloudflare-tunnel-cluster.nix;
        # The homelab scenario: one service set and its migration variants.
        "homelab-kind" = ./how-to/homelab/cluster-kind.nix;
        "homelab-kind-gateway" = ./how-to/homelab/cluster-kind-gateway.nix;
        "homelab-kind-gateway-migrate" = ./how-to/homelab/cluster-kind-gateway-migrate.nix;
        "homelab-kind-tls" = ./how-to/homelab/cluster-kind-tls.nix;
        "homelab-kind-tls-migrate" = ./how-to/homelab/cluster-kind-tls-migrate.nix;
        "homelab-kind-upgrade-small" = ./how-to/homelab/cluster-kind-upgrade-small.nix;
        "homelab-kind-upgrade-broad" = ./how-to/homelab/cluster-kind-upgrade-broad.nix;
        "homelab-kind-pvc-resize" = ./how-to/homelab/cluster-kind-pvc-resize.nix;
        "homelab-kind-storage-migrate" = ./how-to/homelab/cluster-kind-storage-migrate.nix;
        "homelab-kind-db-resize" = ./how-to/homelab/cluster-kind-db-resize.nix;
        "homelab-kind-ns-rename" = ./how-to/homelab/cluster-kind-ns-rename.nix;
        "homelab-kind-pg17" = ./how-to/homelab/cluster-kind-pg17.nix;
        "homelab-kind-env-stamped" = ./how-to/homelab/cluster-kind-env-stamped.nix;
        "homelab-kind-env-stamped-dev-change" = ./how-to/homelab/cluster-kind-env-stamped-dev-change.nix;
      };
    };
  # endregion:mkFlakeOutputs
}
# endregion:exampleFlake
