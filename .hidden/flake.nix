{
  description = "Finished versions of tutorial clusters the docs pipeline captures output against. CONTAINS SPOILERS — see ./README.md.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # TODO: switch to github:adamcharnock/kixpkgs once that repo is public.
    kixpkgs.url = "git+file:///Users/adam/ghq/github.com/adamcharnock/kixpkgs";
    kixpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Mirror the public flake's clusters so the docs pipeline can capture
  # `kix list clusters` against a combined view (what tutorial 04's reader
  # actually sees after they've added 04-from-scratch to their flake).
  # KEEP IN SYNC with ../flake.nix when adding or renaming public clusters.
  outputs =
    inputs:
    inputs.kixpkgs.lib.mkFlake {
      inherit inputs;
      clusters = {
        "02-hello-world" = ../tutorials/02-hello-world/cluster.nix;
        "06-service-dep" = ../tutorials/06-service-dep/cluster.nix;
        "08-namespace-deps" = ../tutorials/08-namespace-deps/cluster.nix;
        "09-typed-options" = ../tutorials/09-typed-options/cluster.nix;
        "10-reuse-packages" = ../tutorials/10-reuse-packages/cluster.nix;
        "19-scorecards" = ../tutorials/19-scorecards/cluster.nix;
        "04-from-scratch" = ./04-from-scratch/cluster.nix;
      };
    };
}
