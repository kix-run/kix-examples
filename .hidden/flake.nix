{
  description = "Finished versions of tutorial clusters the docs pipeline captures output against. CONTAINS SPOILERS — see ./README.md.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # TODO: switch to github:adamcharnock/kixpkgs once that repo is public.
    kixpkgs.url = "git+file:///Users/adam/ghq/github.com/adamcharnock/kixpkgs";
    kixpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    inputs.kixpkgs.lib.mkFlake {
      inherit inputs;
      clusters = {
        "04-from-scratch" = ./04-from-scratch/cluster.nix;
      };
    };
}
