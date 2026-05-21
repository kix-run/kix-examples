# 01 — Hello

The smallest possible Kix cluster: a single `echo-server` instance.

**You'll learn:** how a Kix cluster is structured, how `kix deploy`
builds + applies the manifests, and what the edit/build/apply loop
feels like.

## What's in it

One instance:

```nix
instances.example-01 = {
  hello = {
    package = packages.echo-server;
    config = {
      message = "Hello from Kix!";
    };
  };
};
```

That's it. No deps, no secrets.

## Run

From the repo root (kind cluster assumed already up — see the top-level
[README](../../README.md) if not):

```sh
kix deploy 01-hello -y
kix pf 01-hello hello 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# Hello from Kix!
```

## Things to try

- **Change the message** in `cluster.nix`, then re-run
  `kix deploy 01-hello -y`. Reload `http://localhost:8080` — the new
  value appears.
- **See the rendered manifests:** `kix build 01-hello` prints the YAML
  Kix would apply.
- **Diff against the live cluster:** `kix diff 01-hello`.
- **Inspect the cluster's DI graph:** `kix inspect 01-hello`.

## Next

Once this works, move on to [`02-service-dep`](../02-service-dep/) which
adds a second service and shows how Kix wires one to another's URL.
