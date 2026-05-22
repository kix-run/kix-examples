# 06 — Scorecards

> **Recommended reading:** [05-multi-instance](../05-multi-instance/)
> (the cluster body here is identical to 05's),
> [02-service-dep](../02-service-dep/),
> [03-cross-namespace](../03-cross-namespace/),
> [04-typed-options](../04-typed-options/).

Kix has a compile-time rule engine called the **scorecard**. Rules
run during `nix build` and can fire findings at four levels —
`manifest`, `package`, `namespace`, `cluster` — with `info`,
`warning`, or `error` severity.

`error` findings at the first three levels fail the build; cluster-
level errors land in `result/kix-scorecard.json` (see the note
below). All findings appear in the JSON regardless.

This example reuses the multi-instance shape from `05` so the
cluster-level rule has something interesting to inspect. The
scorecard turns on three rules — one built-in category, one
package-level custom rule, one cluster-level custom rule.

**You'll learn:** how to enable the scorecard, how to use built-ins,
how to override severity, how to write custom rules at different
levels, and which findings can fail the build.

## Layout

```
cluster.nix                # the cluster — instances, namespaces, wiring
scorecard.nix              # the rules we want true about the cluster
reverse-proxy-package.nix  # unchanged from 05
```

The scorecard lives in its own file because in this example it *is*
the focus. `cluster.nix` just declares the cluster, then imports
the rules:

```nix
# In cluster.nix:
# `lib` is in scope because the surrounding module pulls it from
# the NixOS module-system args.
scorecard = import ./scorecard.nix { inherit lib kix; };
```

## The scorecard

```nix
# In scorecard.nix:
{
  enable = true;

  # Per-rule severity override. Key is `<category>.<rule>`.
  # Lifts a built-in from "warning" to "error" so the build fails
  # (not just warns) if a probe is missing.
  ruleOverrides.byRule."reliability.hasProbes".severity = "error";

  rules = {
    # Whole built-in category. Most production hardening is one line.
    reliability = kix.rules.reliability;

    # Custom rules go under a category name of your choice
    # (we picked `custom`).
    custom.proxyMaxBodySizeMustBeExplicit = { ... };
    custom.noProxyPathCollision = { ... };
  };
}
```

### Rule 1 — Built-in `reliability` + severity override

`kix.rules.reliability` bundles `hasProbes`, `boundedResources`,
`hasResourceLimits`, `hasResourceRequests`, `gracefulShutdown`, and
`hasPDB`. They run as `warning`/`info` by default — production
hardening you can opt into rule-by-rule without writing any rule
code. Severity overrides let you lift a single rule to `error`
without forking it.

### Rule 2 — `proxyMaxBodySizeMustBeExplicit` (package-level)

```nix
custom.proxyMaxBodySizeMustBeExplicit = {
  level = "package";                # sees one instance's config + resources
  severity = "error";

  # Scope the rule: only run on reverse-proxy instances.
  appliesTo = { meta, ... }:
    (meta.description or "") == proxyDescription;

  # Fire if the instance still uses the default body size.
  check = { config, instanceName, ... }:
    if (config.maxBodySize or "") == "1m" then
      [ { message = "instance '${instanceName}' uses the unsafe default ..."; } ]
    else
      [ ];
};
```

Nginx silently rejects bodies larger than its default 1 MB. Encoding
that lesson as a rule forces every cluster operator to set a value
explicitly — the kind of one-liner that turns scar tissue into a
permanent guardrail.

### Rule 3 — `noProxyPathCollision` (cluster-level)

```nix
custom.noProxyPathCollision = {
  level = "cluster";                # sees `allInstances` across every namespace
  severity = "error";

  check = { allInstances, ... }:
    let
      # Flatten { ns = { name = inst; }; } → list of { ns, name, inst }.
      flat = lib.concatLists (
        map (ns: map (name: { inherit ns name; inst = allInstances.${ns}.${name}; })
              (builtins.attrNames allInstances.${ns}))
            (builtins.attrNames allInstances));

      # Keep only reverse-proxy instances.
      proxies = builtins.filter (e: isProxy e.inst) flat;

      # Group by proxyPath → { "/v1/" = [...]; "/v2/" = [...]; }.
      byPath = builtins.foldl' (acc: e:
        let p = e.inst._meta.config.proxyPath or "?";
        in acc // { ${p} = (acc.${p} or []) ++ [ e ]; }
      ) {} proxies;

      # Any path with more than one owner is a collision.
      collisions = lib.filterAttrs (_: members:
        builtins.length members > 1
      ) byPath;
    in
    map (path: { message = "${...}"; }) (builtins.attrNames collisions);
};
```

Only cluster-level rules can catch this — a manifest-level rule sees
one resource at a time, a package-level rule sees one instance.
Cross-instance invariants need the cluster as input.

> [!NOTE]
> **Cluster-level findings don't currently fail `nix build` on their
> own** — they appear in `result/kix-scorecard.json` with the right
> severity, but the build keeps going.
> Manifest/package/namespace-level errors *do* fail the build via
> Kix's assertion mechanism (build stops, finding is also in the
> JSON). In production, CI tooling should read the JSON and fail
> if `summary.errors > 0`.

## Run

```sh
# kind cluster assumed up — see the top-level README if not
kix deploy 06-scorecards -y

# As 05, two terminals.
kix pf 06-scorecards -n app-v1 gateway 8081:80    # blocks
kix pf 06-scorecards -n app-v2 gateway 8082:80    # other terminal
```

```sh
curl http://localhost:8081/v1/   # → Response from app-v1
curl http://localhost:8082/v2/   # → Response from app-v2
```

Inspect findings:

```sh
cat result/kix-scorecard.json | jq .summary
cat result/kix-scorecard.json | jq '.findings[] | select(.severity=="error")'
```

## Things to try

- **Force a probe miss:** delete `livenessProbe` from
  `reverse-proxy-package.nix`. Build fails with a clear assertion
  message — that's `reliability.hasProbes` + the severity override
  working together.
- **Force a body-size default:** change `maxBodySize = "10m";` to
  `maxBodySize = "1m";`. Build fails (package-level error).
- **Force a path collision:** change `proxyPath = "/v2/";` to
  `"/v1/";`. Build succeeds, but the finding appears in
  `result/kix-scorecard.json` (see the note above on cluster-level
  rules).
- **Soften a built-in:** add
  `byRule."reliability.boundedResources".severity = "info";`. The
  resource-limit warnings drop in severity.
- **Disable a rule:** add
  `byRule."reliability.gracefulShutdown".enabled = false;`. It
  disappears from the report entirely.
