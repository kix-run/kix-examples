# 03 — Cross-namespace dep

Same gateway-and-backend shape as `02-service-dep`, but the two
instances now live in **different namespaces**: the backend in
`platform`, the gateway in `app`.

**You'll learn:** how to wire a dep across a namespace boundary using
`ref.<ns>.<inst>`, and why being explicit at the boundary is worth a
line of code.

## Layout

```
cluster.nix                # two namespaces, two instances, explicit ref
reverse-proxy-package.nix  # same package as in 02 (copy)
```

The reverse-proxy package is a verbatim copy of the one in
`02-service-dep` — kept local so each example folder reads in
isolation.

## Instances

| Namespace | Name | Package | Role |
|---|---|---|---|
| `platform` | `backend` | `echo-server` (from kixpkgs) | answers HTTP with a fixed message |
| `app` | `gateway` | `./reverse-proxy-package.nix` | nginx reverse-proxy in front of `backend` |

## How the wiring works

```nix
# Same package signature as 02 — the proxy declares a `backend` dep.
build = { self, scope, kix, backend, ... }: { ... };
```

```nix
# The gateway lives in `app`, but `backend` lives in `platform`.
# Name-matching only looks within the same namespace, so we wire it
# out explicitly. `ref.<ns>.<inst>` reaches into another namespace
# and resolves to that instance.
gateway = {
  package = reverseProxyPackage;
  deps.backend = ref.platform.backend;
};
```

### Wait, doesn't Kix find it automatically?

Yes — Kix's resolver has a cluster-wide fallback that would discover
`backend` in `platform` even without the `deps` line. Reasons to
write it out anyway:

- **Visibility.** A reader of `app/gateway` sees the dep without
  jumping namespaces.
- **Safety.** The fallback is convenient for platform imports (DNS,
  CNI, etc.) but means two unrelated namespaces could race for the
  same generic name. Explicit `ref` lines never race.
- **Refactor-resistance.** If someone later renames `platform.backend`
  or adds another `backend` elsewhere, the explicit `ref` keeps
  pointing at one specific instance — the auto-resolution would
  silently switch.

See [kixpkgs issue #19](https://github.com/adamcharnock/kixpkgs/issues/19)
for a discussion on making cross-namespace resolution opt-in.

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 03-cross-namespace -y
kix pf 03-cross-namespace gateway 8080:80    # blocks; Ctrl-C to stop
```

```sh
curl http://localhost:8080/
# Hello from the platform-owned backend!
```

The gateway in `app` is proxying to the backend in `platform`.

## Things to try

- **Drop the `deps` line.** Comment it out and re-run
  `kix deploy 03-cross-namespace -y`. It still works — that's the
  cluster-wide auto-resolution the explicit line was guarding
  against.
- **Cause a collision.** Add a second `backend` instance in a new
  namespace and watch what happens.
- **Inspect the dep graph:** `kix inspect 03-cross-namespace`.
- **Hit the backend directly:** `kix pf 03-cross-namespace backend 8081:80`.

## Next

Move on to [`04-typed-options`](../04-typed-options/), which gives the
reverse-proxy package typed config options validated at build time.
