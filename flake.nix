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
        "01-hello-world" = ./examples/01-hello-world/cluster.nix;
        "02-service-dep" = ./examples/02-service-dep/cluster.nix;
        "03-cross-namespace" = ./examples/03-cross-namespace/cluster.nix;
        "04-typed-options" = ./examples/04-typed-options/cluster.nix;
        "05-multi-instance" = ./examples/05-multi-instance/cluster.nix;
        "06-scorecards" = ./examples/06-scorecards/cluster.nix;
      };
    };
}
