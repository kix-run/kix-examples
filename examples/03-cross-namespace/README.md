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

The gateway's package still asks for a `backend` arg:

```nix
build = { self, scope, kix, backend, ... }: { ... };
```

But the gateway now sits in the `app` namespace, where no `backend`
instance exists. So we wire it out explicitly:

```nix
gateway = {
  package = reverseProxyPackage;
  deps.backend = ref.platform.backend;
};
```

`ref.platform.backend` reaches into the `platform` namespace and
resolves to the `backend` instance there.

### Wait, doesn't Kix find it automatically?

Yes, it would — Kix's resolver also has a cluster-wide fallback
(`other-namespace match`) that would discover `backend` in `platform`
even without the `deps` line. So why write it out?

- **Visibility.** A reader of `app/gateway` can see the dep without
  jumping namespaces.
- **Safety.** The cluster-wide fallback is convenient for platform
  imports (DNS, CNI, etc.) but means two unrelated namespaces could
  race for the same generic name. Explicit `ref` lines never race.
- **Refactor-resistance.** If someone later renames `platform.backend`
  or adds another `backend` elsewhere, the explicit `ref` points at
  one specific instance — the auto-resolution would silently switch.

See [kixpkgs issue #19](https://github.com/adamcharnock/kixpkgs/issues/19)
for a discussion on making cross-namespace resolution opt-in.

## Run

From the repo root (kind cluster assumed already up — see the top-level
[README](../../README.md) if not):

```sh
kix deploy 03-cross-namespace -y
kix pf 03-cross-namespace gateway 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# Hello from the platform-owned backend!
```

The gateway in `app` is proxying to the backend in `platform`.

## Things to try

- **Drop the `deps` line.** Comment it out and re-run
  `kix deploy 03-cross-namespace -y`. It still works — Kix's
  cluster-wide fallback finds `backend` in `platform`. Now you've seen
  exactly the auto-resolution behaviour the explicit line was
  protecting you from.
- **Cause a collision.** Add a second `backend` instance in a new
  namespace and watch what happens.
- **Inspect the dep graph:** `kix inspect 03-cross-namespace`.
- **Hit the backend directly:** `kix pf 03-cross-namespace backend 8081:80`,
  then `curl http://localhost:8081/`.
