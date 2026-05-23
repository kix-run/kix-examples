# region:exampleFlake
{
  description = "Kix example clusters — a tour of Kix patterns runnable on kind.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # TODO: switch to github:adamcharnock/kixpkgs once that repo is public.
    # git+file: respects .gitignore so the 9 GB of build artifacts in the
    # local kixpkgs tree don't get copied into the Nix store on every build.
    kixpkgs.url = "git+file:///Users/adam/ghq/github.com/adamcharnock/kixpkgs";
    kixpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Each example folder has its own cluster.nix. Add a new example by
  # appending a line here and creating examples/NN-name/cluster.nix.
  outputs =
    inputs:
    inputs.kixpkgs.lib.mkFlake {
      inherit inputs;
      clusters = {
        "02-hello-world" = ./examples/02-hello-world/cluster.nix;
        "06-service-dep" = ./examples/06-service-dep/cluster.nix;
        "08-namespace-deps" = ./examples/08-namespace-deps/cluster.nix;
        "09-typed-options" = ./examples/09-typed-options/cluster.nix;
        "10-reuse-packages" = ./examples/10-reuse-packages/cluster.nix;
        "19-scorecards" = ./examples/19-scorecards/cluster.nix;
      };
    };
}
# endregion:exampleFlake
