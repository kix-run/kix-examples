# region:exampleFlake
{
  description = "Kix example clusters — a tour of Kix patterns runnable on kind.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Fetched via the GitHub fetcher. While the repo is private, every
    # consumer (local dev, kixpkgs CI, the captures pipeline) must
    # provide a token: `gh auth token` plugged into nix.conf
    # `access-tokens = github.com=...`, or the workflow's auto-issued
    # GITHUB_TOKEN. The kixpkgs captures pipeline rewrites this URL
    # to `path:<store>` and drops flake.lock before invoking kix, so
    # its sandboxed eval never hits the network. (kix's clap CLI
    # doesn't forward `--override-input`, so the rewrite is the only
    # in-band knob.)
    kixpkgs.url = "github:adamcharnock/kixpkgs";
    kixpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Each example folder has its own cluster.nix. Add a new example by
  # appending a line here and creating examples/NN-name/cluster.nix.
  # region:mkFlakeOutputs
  outputs =
    inputs:
    inputs.kixpkgs.lib.mkFlake {
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
        "how-to-package-python" = ./how-to/package-stacks/python-cluster.nix;
        "how-to-package-stackgres" = ./how-to/package-stacks/stackgres-cluster.nix;
        "how-to-package-monitoring" = ./how-to/package-stacks/monitoring-cluster.nix;
        "how-to-package-cert-manager" = ./how-to/package-stacks/cert-manager-cluster.nix;
        "how-to-package-cilium" = ./how-to/package-stacks/cilium-cluster.nix;
        "how-to-package-valkey" = ./how-to/package-stacks/valkey-cluster.nix;
        "how-to-package-victoria-metrics" = ./how-to/package-stacks/victoria-metrics-cluster.nix;
        "how-to-platform-gateway" = ./how-to/platform/gateway-cluster.nix;
        "how-to-platform-hostpath" = ./how-to/platform/hostpath-cluster.nix;
        "how-to-platform-ingress" = ./how-to/platform/ingress-cluster.nix;
        "how-to-platform-monitoring" = ./how-to/platform/monitoring-cluster.nix;
        "how-to-platform-network-policy" = ./how-to/platform/network-policy-cluster.nix;
        "how-to-platform-secrets" = ./how-to/platform/secrets-cluster.nix;
      };
    };
  # endregion:mkFlakeOutputs
}
# endregion:exampleFlake
