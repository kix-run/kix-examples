# 03 — Cross-namespace dep

> **Recommended reading:** [02-service-dep](../02-service-dep/).
> This example assumes you know how a package asks for `backend`.

Same gateway-and-backend shape as `02-service-dep`, but the two
instances now live in **different namespaces**: the backend in
`platform`, the gateway in `app`.

**You'll learn:** how to wire a dep across a namespace boundary with
`ref.<ns>.<inst>`, and why explicit wiring is clearer at namespace
boundaries.

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

The reverse-proxy package is the same shape as in `02-service-dep`: its
`build` function declares a `backend` dep.

The difference is in `cluster.nix`. Look at `instances.app.gateway`:
the gateway lives in `app`, while the backend lives in `platform`, so
the gateway writes the dependency explicitly with `ref.platform.backend`.
That `ref.<ns>.<inst>` form reaches into another namespace and resolves
to that exact instance.

### Wait, doesn't Kix find it automatically?

Yes. Kix's resolver has a cluster-wide fallback that would discover
`backend` in `platform` even without the `deps` line. Reasons to
write it out anyway:

- **Visibility.** A reader of `app/gateway` sees the dep without
  jumping namespaces.
- **Safety.** The fallback is convenient for platform imports (DNS,
  CNI, etc.), but two unrelated namespaces can still use the same
  generic instance name. Explicit `ref` lines avoid that ambiguity.
- **Refactor-resistance.** If someone later renames `platform.backend`
  or adds another `backend` elsewhere, the explicit `ref` still points
  at one specific instance.

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
  cluster-wide fallback. The explicit line is there to make the
  boundary crossing obvious.
- **Cause a collision.** Add a second `backend` instance in a new
  namespace and watch what happens.
- **Inspect the dep graph:** `kix inspect 03-cross-namespace`.
- **Hit the backend directly:** `kix pf 03-cross-namespace backend 8081:80`.

## Next

Move on to [`04-typed-options`](../04-typed-options/), which gives the
reverse-proxy package typed config options validated at build time.
