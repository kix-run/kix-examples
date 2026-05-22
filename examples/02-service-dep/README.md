# 02 — Service dep

A cluster with **one service talking to another**: an nginx gateway
that reverse-proxies to a backend echo-server. The gateway picks up
the backend's in-cluster DNS name + port from the backend's `out` API
at compile time — no string interpolation, no hardcoded hostnames.

**You'll learn:** how packages declare deps and how Kix wires them by
name; how to define a package locally to this repo instead of in
kixpkgs.

## Layout

```
cluster.nix                # wiring: namespaces, instances
reverse-proxy-package.nix  # local package: nginx reverse-proxy
```

The file name describes the *package* (a reverse-proxy); the cluster
instantiates it as an *instance* named `gateway`. Kix keeps those
concepts distinct — one package can back many instances (you'll see
this in `05-multi-instance`). kixpkgs follows the same naming
convention (`echo-server`, `secret-echo`, …).

Local packages today are imported by path:

```nix
# In cluster.nix:
# `mkFlake` only reads its catalog from `kix/packages/` in kixpkgs,
# so anything local to this repo just sits next to cluster.nix and
# gets `import`-ed by hand.
let reverseProxyPackage = import ./reverse-proxy-package.nix;
in ...
```

## Instances

| Name | Package | Role |
|---|---|---|
| `backend` | `echo-server` (from kixpkgs) | answers HTTP with a fixed message |
| `gateway` | `./reverse-proxy-package.nix` | nginx reverse-proxy in front of `backend` |

## How the wiring works

```nix
# The proxy package's build function takes a `backend` arg.
# Kix resolves deps by matching the arg name to an instance name in
# the same namespace — consistent naming is the only contract.
build = { self, scope, kix, backend, ... }: { ... };
```

```nix
# Inside the build, `backend` is the live `out` API of the resolved
# instance. `${backend.out.fqdn}` is `backend.example-02.svc.cluster.local`;
# `out.port` is the Service's port. Both carry Nix string context, so
# the resulting ConfigMap ends up with a `kix.dev/depends-on`
# annotation — the deploy DAG falls out automatically.
location / {
    proxy_pass http://${backend.out.fqdn}:${backend.out.port}/;
}
```

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 02-service-dep -y
kix pf 02-service-dep gateway 8080:80    # blocks; Ctrl-C to stop
```

```sh
curl http://localhost:8080/
# Hello from the backend!
```

The reply comes from the **`backend` pod** — the gateway is just
proxying. Two ClusterIP Services, Kix-derived DNS, no Ingress, no
LoadBalancer.

## Things to try

- **See the wiring:** `kix build 02-service-dep` prints the YAML. Look
  at the gateway's ConfigMap — the `proxy_pass` URL has the real FQDN
  baked in. Note the `kix.dev/depends-on` annotation pointing at the
  backend.
- **Rename the backend:** change `backend = { … }` to `api = { … }`
  and rebuild. Kix can't find a `backend` for the gateway and refuses
  the build. Add `aliases = [ "backend" ]` on `api` to restore the
  link — that's what aliases are for: letting an instance be referred
  to by a role name distinct from its own.
- **Inspect the dep graph:** `kix inspect 02-service-dep`.
- **Hit the backend directly:** `kix pf 02-service-dep backend 8081:80`.

## Next

Move on to [`03-cross-namespace`](../03-cross-namespace/), which puts
the backend and gateway in separate namespaces and writes the dep out
explicitly with `ref`.
