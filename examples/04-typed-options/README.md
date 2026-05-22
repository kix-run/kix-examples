# 04 — Typed package options

> **Recommended reading:** [02-service-dep](../02-service-dep/),
> [03-cross-namespace](../03-cross-namespace/). This example assumes
> you know what `package`, `config`, `deps`, and `ref` mean.

The reverse-proxy package now declares typed configuration **options**.
The cluster passes values in; the package validates them at build
time. A bad path or body-size value becomes a build error instead of a
surprise in nginx.

**You'll learn:** how a package exposes its config surface using
`lib.mkOption` + `lib.types`, and how the cluster supplies values.

## Layout

```
cluster.nix                # supplies option values for the gateway
reverse-proxy-package.nix  # declares typed `options`
```

## The Options

Open `reverse-proxy-package.nix` and look at the `options` attrset.
It declares two knobs:

- `proxyPath`, whose type requires a leading `/`
- `maxBodySize`, whose type accepts nginx body-size values such as
  `"100k"`, `"1m"`, or `"50M"`

Both are built with `lib.mkOption`, so their defaults, descriptions,
examples, and types become part of the package's config contract.

## Supplying values from the cluster

Open `cluster.nix` and look at `instances.example-04.gateway`. Its
`config` attrset supplies values for those package options, and
`deps.backend` still points the gateway at the backend instance.

Inside the package's `build` function, those values arrive as
`config.proxyPath` and `config.maxBodySize`. It is the same `config`
argument you saw in `01-hello-world`; the difference is that the
package now declares what values are valid.

## Why types here matter

Without types, `proxyPath = "api"` would build and nginx would serve a
different route than you intended. With `lib.types.strMatching`, the
same typo gives you:

```text
error: A definition for option `proxyPath' is not of type
       `string matching the pattern ^/.*$'. Definition values:
       - In `<unknown-file>': "api"
```

at `nix build` time, before any pod runs.

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 04-typed-options -y
kix pf 04-typed-options gateway 8080:80    # blocks; Ctrl-C to stop
```

```sh
curl http://localhost:8080/
# Hello from the backend!
```

## Things to try

- **Break the path type:** set `proxyPath = "api";` (no slash) and run
  `nix build .#cluster-04-typed-options`.
- **Break the body-size type:** set `maxBodySize = "1mb";` (wrong
  suffix).
- **Use the type for documentation:** `kix inspect 04-typed-options`
  shows option descriptions and examples.

## Next

Move on to [`05-multi-instance`](../05-multi-instance/), which uses
the same package to run two gateways with different config.
