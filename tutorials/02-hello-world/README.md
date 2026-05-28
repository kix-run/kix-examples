# 02 — Hello world

> **New to Nix?** The [glossary in the root README](../../README.md#glossary)
> defines every Nix construct used in these examples (attrsets, `let`,
> multi-line strings, the pipe operator, `lib.mkOption`, etc.). Keep
> it open in a second tab while you walk through these.

The smallest useful Kix cluster: one `echo-server` instance in one
namespace.

**You'll learn:** where workloads live in `cluster.nix`, what
`kix deploy` does, and how the edit/build/apply loop feels.

## What's in it

Open `cluster.nix` and look at `instances.tutorial-02`. There is one
instance named `hello-world`, backed by the `packages.echo-server`
package from kixpkgs.

The only config value is `message`, which becomes the HTTP response
body. That is the smallest useful edit point in this repo: change the
message, deploy again, and curl the service.

## Run

From the repo root, with the kind cluster already running:

```sh
kix deploy 02-hello-world -y
kix pf 02-hello-world hello-world 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# Hello from Kix!
```

## Things to try

- **Change the message** in `cluster.nix`, then re-run
  `kix deploy 02-hello-world -y`. Reload `http://localhost:8080` — the
  new value appears.
- **See the rendered manifests:** `kix build 02-hello-world` prints
  the YAML Kix would apply.
- **Diff against the live cluster:** `kix diff 02-hello-world`.
- **Inspect the cluster's DI graph:** `kix inspect 02-hello-world`.

## Next

Once this works, move on to
[`06-service-dep`](../06-service-dep/).
It adds a second service and shows how Kix wires one workload to another.
