# 02 — Service dep

A cluster with **one service talking to another**: an nginx gateway
that reverse-proxies to a backend echo-server. The gateway pulls the
backend's in-cluster DNS name and port from the backend's `out` API at
compile time.

**You'll learn:** how Kix exposes a service's derived properties
(`out.fqdn`, `out.port`) and how a consumer package automatically picks
up the right provider — no string interpolation, no hardcoded
hostnames, no explicit wiring required.

## Layout

```
cluster.nix         # wiring: namespaces, instances
reverse-proxy-package.nix   # local package: nginx reverse-proxy
```

The file is named for the *package* (a reverse-proxy), not the
*instance* (named `gateway` below). One package can back many instances,
so Kix keeps those concepts distinct — kixpkgs follows the same
convention (`echo-server`, `secret-echo`, …).

`reverse-proxy-package.nix` is shaped exactly like a real Kix package: an
attrset with `meta` + `build`, where `build` declares the deps it needs
as named args. `cluster.nix` pulls it in with
`let reverseProxyPackage = import ./reverse-proxy-package.nix;`.

That's the pattern for local packages today: Kix's `mkFlake` only reads
its catalog from `kix/packages/` in kixpkgs, so anything specific to
your repo just sits next to `cluster.nix` and gets imported.

## Instances

| Name | Package | Role |
|---|---|---|
| `backend` | `echo-server` (from kixpkgs) | answers HTTP with a fixed message |
| `gateway` | `./reverse-proxy-package.nix` | nginx reverse-proxy in front of `backend` |

## How the wiring works

The proxy package's `build` function asks for a `backend` arg:

```nix
build = { self, scope, kix, backend, ... }: { ... };
```

The cluster has an instance literally named `backend`. **That's the
whole wiring** — Kix resolves deps by matching the build arg name to
an instance name in the same namespace. Consistent naming is the only
contract.

Inside the package, that `backend` arg is the live `out` API of the
instance:

```nix
location / {
    proxy_pass http://${backend.out.fqdn}:${backend.out.port}/;
}
```

`out.fqdn` is `backend.example-02.svc.cluster.local`; `out.port` is the
Service's port. Both are derived from the `backend` instance — and
because Kix routes them through Nix string context, the gateway's
ConfigMap ends up with a `kix.dev/depends-on` annotation pointing at
the backend's resources. The deploy order falls out automatically.

## Run

From the repo root (kind cluster assumed already up — see the top-level
[README](../../README.md) if not):

```sh
kix deploy 02-service-dep -y
kix pf 02-service-dep gateway 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# Hello from the backend!
```

The reply comes from the **`backend` pod** — the gateway is just
proxying. There's no Ingress, no LoadBalancer, just two ClusterIP
Services and Kix-derived DNS.

## Things to try

- **See the wiring:** `kix build 02-service-dep` prints the YAML. Look
  at the gateway's ConfigMap — the `proxy_pass` URL has the real FQDN
  baked in. Also note the `kix.dev/depends-on` annotation pointing at
  the backend.
- **Rename the backend:** change `backend = { … }` to
  `api = { … }` and re-run `kix build`. Kix can't find a `backend` for
  the gateway and refuses the build. Add `aliases = [ "backend" ]` on
  `api` to restore the link — that's what aliases are for: letting an
  instance be referred to by a role name distinct from its own.
- **Inspect the dep graph:** `kix inspect 02-service-dep`.
- **Hit the backend directly:** `kix pf 02-service-dep backend 8081:80`,
  then `curl http://localhost:8081/` — same response, no gateway in
  the path.

## Next

Move on to [`03-cross-namespace`](../03-cross-namespace/), which puts
the backend and gateway in separate namespaces and writes the dep out
explicitly with `ref`.
