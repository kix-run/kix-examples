# 05 — Multi-instance

> **Recommended reading:** [04-typed-options](../04-typed-options/)
> (the reverse-proxy package here is a direct copy from 04),
> [02-service-dep](../02-service-dep/),
> [03-cross-namespace](../03-cross-namespace/).

A Kix **package** is a parameterised blueprint; an **instance** is a
deployed copy of it with config wired in. One package can back any
number of instances — same code, different parameters.

This example puts two parallel mini-stacks in the same cluster:
`app-v1` and `app-v2`, each with its own backend + gateway. Same
packages, different instances, different config.

**You'll learn:** how to instantiate the same package multiple times,
and why the `package`/`instance` split is what makes Kix scale to a
real cluster.

## Layout

```
cluster.nix                # four instances across two namespaces
reverse-proxy-package.nix  # unchanged from 04
```

## Shape

```nix
# Each namespace carries one backend + one gateway. Both pairs use
# the same packages — `echo-server` and `reverseProxyPackage` — but
# get different config and end up as distinct instances.
instances.app-v1 = {
  backend = {
    package = packages.echo-server;
    config.message = "Response from app-v1";
  };
  gateway = {
    package = reverseProxyPackage;
    config.proxyPath = "/v1/";
    ...
  };
};

instances.app-v2 = {
  backend = {
    package = packages.echo-server;
    config.message = "Response from app-v2";
  };
  gateway = {
    package = reverseProxyPackage;
    config.proxyPath = "/v2/";
    ...
  };
};
```

Kix renders each instance independently: four Deployments, four
Services, four ConfigMaps, two namespaces. Each
`deps.backend = ref.app-vN.backend` wires only its local pair —
no cross-talk.

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 05-multi-instance -y

# Two terminals: one port-forward per gateway.
kix pf 05-multi-instance -n app-v1 gateway 8081:80    # blocks
kix pf 05-multi-instance -n app-v2 gateway 8082:80    # other terminal
```

```sh
curl http://localhost:8081/v1/   # → Response from app-v1
curl http://localhost:8082/v2/   # → Response from app-v2
```

## Things to try

- **Add a third stack.** Copy the v2 block, rename to `app-v3`, change
  the message and `proxyPath`. `kix deploy` and a third
  `curl http://localhost:8083/v3/` should just work.
- **Inspect:** `kix list packages --cluster 05-multi-instance` shows
  which packages back which instances.
- **Diff the rendered YAML:** `kix build 05-multi-instance` — the
  v1 and v2 ConfigMaps are byte-for-byte different despite coming
  from the same package.

## Next

Move on to [`06-scorecards`](../06-scorecards/), which turns on
Kix's compile-time rule engine and uses a multi-instance layout
like this one to demonstrate cluster-level rules.
