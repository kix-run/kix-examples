# kix-examples

A tour of [Kix](https://kixops.dev) patterns, presented as a series of
small clusters you can run locally on [kind](https://kind.sigs.k8s.io/).

Each example is a single folder under `examples/` containing its own
`cluster.nix` and a focused `README.md`. They're numbered in order of
increasing complexity — start at `01-hello` and walk forward.

> [!NOTE]
> While `adamcharnock/kixpkgs` is private, `flake.nix` points at a local
> filesystem path (`git+file:///Users/adam/ghq/github.com/adamcharnock/kixpkgs`).
> To share this repo with someone else, make `kixpkgs` public and switch
> the input to `github:adamcharnock/kixpkgs`, or have them clone
> `kixpkgs` locally and edit the path.

## Prerequisites

- **[Nix](https://nixos.org/download)** with flakes enabled
- **[kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)**
- **kubectl**
- **Docker** (or Colima / OrbStack on macOS) — kind runs the cluster as a
  container, so a Docker-compatible daemon must be up
- **kix CLI** — install once with:
  ```sh
  nix profile install git+file:///Users/adam/ghq/github.com/adamcharnock/kixpkgs#kix
  ```

## Quick start

Four commands take you from nothing to a running Kix cluster:

```sh
# 1. Create the kind cluster (one-time)
kind create cluster --config kind-config.yaml

# 2. Build and apply
kix deploy 01-hello -y

# 3. Port-forward in this terminal (Ctrl-C to stop)
kix pf 01-hello hello 8080:80
```

Then in another terminal:

```sh
curl http://localhost:8080/
```

## Switching examples

Each example uses its own namespace(s) so they coexist on the same
kind cluster:

```sh
kix deploy 02-service-dep -y
kix pf 02-service-dep gateway 8080:80
```

## Glossary

If you know K8s but are new to Nix/Kix, these are the terms that
show up most.

**Kix**

- **Package** — a parameterised blueprint for a K8s service. Closest
  analogue: a Helm chart, but evaluated by Nix.
- **Instance** — a deployed copy of a package, with config and deps
  wired in. Defined under `instances.<ns>.<name>` in `cluster.nix`.
- **Dep** — a reference from one instance to another
  (`deps.backend = ref.platform.backend;`). An explicit edge in the
  service graph.
- **Scope** — per-instance context Kix passes into a package's `build`
  function. Carries the instance name, target namespace, label
  conventions, and helpers like `mkResource` / `mkDeployment`.
- **`out`** — the public interface of a resource or instance: `name`,
  `fqdn`, `port`, `selector`, etc. Use these instead of hardcoded
  strings — they carry the dep edges Kix uses to order deploys.
- **Root** — the "main" resource of a package; what other packages
  receive when they reference *this* instance.
- **Flavor** — a platform profile (`kix.flavors.kind`, `.k3s`, `.eks`,
  ...). Sets defaults that match the target environment.

**Nix language**

- **Attrset** — a dictionary / map / record. Written `{ a = 1; b = "x"; }`.
- **`inherit foo`** — shorthand for `foo = foo;`. Copies a binding from
  the surrounding scope into an attrset.
- **`let ... in ...`** — local variable bindings. Like `let` in JS or
  `where` in Haskell.
- **`{ x, y, ... }:`** — destructured function args. The `...` means
  "and accept any other named args without complaint". Like `**kwargs`
  in Python.
- **`x |> myFunc`** — the pipe operator. Same as `myFunc(x)`, but reads
  left-to-right. (Requires the `pipe-operators` experimental feature.)
- **`${...}` inside `"..."`** — string interpolation, same as JS
  template literals.

## Other useful kix commands

```sh
kix list clusters                       # what's defined in flake.nix
kix list packages --cluster 02-service-dep
kix status 02-service-dep               # resource health table
kix diff 02-service-dep                 # what would change
kix inspect 02-service-dep              # DI deps, parts, out
kix rollback 02-service-dep             # roll back to previous activation
```

## Cleanup

```sh
kind delete cluster --name kix-demo
```

## Layout

```
flake.nix                   # mkFlake exposing every example as cluster-<name>
kind-config.yaml            # kind cluster config (single control-plane node)
examples/
  01-hello/                 # README + cluster.nix
  02-service-dep/           # README + cluster.nix + reverse-proxy-package.nix
  03-cross-namespace/       # README + cluster.nix + reverse-proxy-package.nix
```
