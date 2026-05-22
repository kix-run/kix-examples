# 04 — Typed package options

> **Recommended reading:** [02-service-dep](../02-service-dep/),
> [03-cross-namespace](../03-cross-namespace/). This example assumes
> you know what `package`, `config`, `deps`, and `ref` mean.

The reverse-proxy package now declares typed configuration **options**.
The cluster passes values in; the package validates them at build
time. Typos become build errors, not runtime 5xx.

**You'll learn:** how a package exposes its config surface using
`lib.mkOption` + `lib.types`, and how the cluster supplies values.

## Layout

```
cluster.nix                # supplies option values for the gateway
reverse-proxy-package.nix  # declares typed `options`
```

## The package's options

```nix
# In reverse-proxy-package.nix:
options = {
  # `lib.types.strMatching` runs the regex at module-merge time.
  # `proxyPath = "api"` (no leading slash) fails the build outright,
  # before any K8s manifest is rendered.
  proxyPath = lib.mkOption {
    type = lib.types.strMatching "^/.*$";
    default = "/";
    description = "URL path this proxy forwards. Must start with `/`.";
    example = "/api/";
  };

  # Nginx body-size format: number with optional k/K/m/M/g/G suffix.
  # `"1mb"` fails (wrong suffix); `"10m"` passes.
  maxBodySize = lib.mkOption {
    type = lib.types.strMatching "^[0-9]+[kKmMgG]?$";
    default = "1m";
    description = ''
      Max request body size, in nginx format (e.g. "1m", "100k", "50M").
    '';
    example = "10m";
  };
};
```

## Supplying values from the cluster

```nix
# In cluster.nix:
gateway = {
  package = reverseProxyPackage;
  config = {
    proxyPath = "/";       # the type forces a leading "/"
    maxBodySize = "10m";   # the type forces a valid nginx size suffix
  };
  deps.backend = ref.example-04.backend;
};
```

Inside the package's `build` function, those values arrive as
`config.proxyPath` and `config.maxBodySize` — same `config` arg
you've seen since `01-hello-world`, but now richer and validated.

## Why types here matter

Without types, `proxyPath = "api"` would silently build, and the bug
would surface as a 404 at request time. With `lib.types.strMatching`,
the same typo gives you:

```text
error: A definition for option `proxyPath' is not of type
       `string matching the pattern ^/.*$'. Definition values:
       - In `<unknown-file>': "api"
```

— at `nix build` time, before any pod runs.

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
the same package to back two different instances with different
configs — the natural follow-on now that the package has knobs worth
turning.
