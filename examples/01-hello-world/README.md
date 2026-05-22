# 01 — Hello world

> **New to Nix?** The [glossary in the root README](../../README.md#glossary)
> defines every Nix construct used in these examples (attrsets, `let`,
> multi-line strings, the pipe operator, `lib.mkOption`, etc.). Keep
> it open in a second tab while you walk through these.

The smallest useful Kix cluster: one `echo-server` instance in one
namespace.

**You'll learn:** where workloads live in `cluster.nix`, what
`kix deploy` does, and how the edit/build/apply loop feels.

## What's in it

```nix
# `instances.<namespace>.<name>` is where every workload lives.
# One instance here: name `hello-world`, in namespace `example-01`.
instances.example-01 = {
  hello-world = {
    # The `echo-server` package ships in kixpkgs and serves a fixed
    # message over HTTP.
    package = packages.echo-server;

    # `config` is whatever the package's options accept.
    # echo-server's `message` becomes the body of every response.
    config = {
      message = "Hello from Kix!";
    };
  };
};
```

## Run

From the repo root, with the kind cluster already running:

```sh
kix deploy 01-hello-world -y
kix pf 01-hello-world hello-world 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# Hello from Kix!
```

## Things to try

- **Change the message** in `cluster.nix`, then re-run
  `kix deploy 01-hello-world -y`. Reload `http://localhost:8080` — the
  new value appears.
- **See the rendered manifests:** `kix build 01-hello-world` prints
  the YAML Kix would apply.
- **Diff against the live cluster:** `kix diff 01-hello-world`.
- **Inspect the cluster's DI graph:** `kix inspect 01-hello-world`.

## Next

Once this works, move on to [`02-service-dep`](../02-service-dep/).
It adds a second service and shows how Kix wires one workload to
another.
