# 06 — First local package and service-to-service dependency

> **Recommended reading:** [02-hello-world](../02-hello-world/).
> This example assumes you know where `instances` live in `cluster.nix`.

This cluster has **one service talking to another**: an nginx gateway
reverse-proxies to a backend echo-server. The gateway gets the backend's
in-cluster DNS name and port from the backend's `out` API, so the proxy
config is derived from the dependency graph instead of hand-written
hostnames.

**You'll learn:** how a package asks for a dependency, how Kix resolves
that dependency by name, and how to keep a package local to an example
folder.

## Layout

```
cluster.nix                # wiring: namespaces, instances
reverse-proxy-package.nix  # local package: nginx reverse-proxy
```

The file name describes the *package*: a reverse-proxy. The cluster
instantiates that package as an *instance* named `gateway`. Kix keeps
those concepts separate because one package can back many instances;
`10-reuse-packages` shows that directly. kixpkgs follows the same
naming convention for package files such as `echo-server` and
`secret-echo`.

For now, local packages are imported by path. In `cluster.nix`, look
at the `let` block near the top: it imports `./reverse-proxy-package.nix`
and binds it as `reverseProxyPackage` for the instance definitions
below.

## Instances

| Name | Package | Role |
|---|---|---|
| `backend` | `echo-server` (from kixpkgs) | answers HTTP with a fixed message |
| `gateway` | `./reverse-proxy-package.nix` | nginx reverse-proxy in front of `backend` |

## How the wiring works

Open `reverse-proxy-package.nix` and look at the package's `build`
function. It asks for a `backend` argument. Kix resolves that dep by
looking for an instance with the same name in the same namespace.

In the `configmap` resource, nginx uses `backend.out.fqdn` and
`backend.out.port` to build the `proxy_pass` target. Those values are
the backend Service DNS name and port, and using them gives Kix enough
information to apply the backend before the gateway.

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 06-service-dep -y
kix pf 06-service-dep gateway 8080:80    # blocks; Ctrl-C to stop
```

```sh
curl http://localhost:8080/
# Hello from the backend!
```

The reply comes from the **`backend` pod**. The gateway is only
proxying: two ClusterIP Services, Kix-derived DNS, no Ingress, no
LoadBalancer.

## Things to try

- **See the wiring:** `kix build 06-service-dep` prints the YAML. Look
  at the gateway's ConfigMap — the `proxy_pass` URL has the real FQDN
  baked in. Note the `kix.run/depends-on` annotation pointing at the
  backend.
- **Rename the backend:** change `backend = { ... }` to `api = { ... }`
  and rebuild. Kix can't find a `backend` for the gateway and refuses
  the build. Add `aliases = [ "backend" ]` on `api` to restore the
  link. Aliases let an instance have a concrete name, such as `api`,
  while still filling a role name, such as `backend`.
- **Inspect the dep graph:** `kix inspect 06-service-dep`.
- **Hit the backend directly:** `kix pf 06-service-dep backend 8081:80`.

## Next

Move on to
[`08-namespace-deps`](../08-namespace-deps/),
which puts the backend and gateway in separate namespaces and writes the dep
out explicitly with `ref`.
