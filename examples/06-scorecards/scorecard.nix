# scorecard.nix — the rules wired into cluster.nix.
#
# Recommended reading: 05-multi-instance (`noProxyPathCollision`
# only makes sense when there's more than one proxy in the cluster).
#
# Three rules, each at a different scope:
#
#   reliability                       — whole built-in category
#   proxyMaxBodySizeMustBeExplicit    — custom, package-level
#   noProxyPathCollision              — custom, cluster-level
#
# This file is a function `{ lib, kix }: { ... }` so it can use
# `kix.rules.*` and `lib.*` while keeping cluster.nix focused on the
# cluster itself.

{ lib, kix }:

let
  # Reverse-proxy instances are identified by their package's
  # `meta.description`. In production code you'd typically use a
  # `meta.provides` capability marker; the description string is fine
  # for a demo.
  proxyDescription = "nginx reverse-proxy with typed config options";

  isProxy = inst: (inst._meta.packageMeta.description or "") == proxyDescription;
in
{
  enable = true;

  # Per-rule severity override. Key is `<category>.<rule>`.
  # Lifts a built-in from "warning" to "error" so the build fails
  # (not just warns) if a probe is missing.
  ruleOverrides.byRule."reliability.hasProbes".severity = "error";

  rules = {
    # 1. Whole built-in category. Bundles hasProbes,
    #    boundedResources, hasResourceLimits, hasResourceRequests,
    #    gracefulShutdown, hasPDB.
    reliability = kix.rules.reliability;

    # 2. Custom package-level rule. Fires per-instance, with access
    #    to `config` (resolved options) and `resources` for that one
    #    instance.
    custom.proxyMaxBodySizeMustBeExplicit = {
      description = "Reverse-proxy gateways must set maxBodySize explicitly (not the 1m default).";
      level = "package";
      severity = "error";
      tags = [ "reliability" "kix-examples" ];

      # Only run on reverse-proxy instances.
      appliesTo =
        { meta, ... }:
        (meta.description or "") == proxyDescription;

      check =
        { config, instanceName, ... }:
        if (config.maxBodySize or "") == "1m" then
          [
            {
              message =
                "instance '${instanceName}' uses the unsafe default maxBodySize '1m'. "
                + "nginx silently rejects larger bodies — set this explicitly.";
            }
          ]
        else
          [ ];
    };

    # 3. Custom cluster-level rule. Sees `allInstances` (across every
    #    namespace). The only level that can catch cross-instance
    #    invariants.
    custom.noProxyPathCollision = {
      description = "No two reverse-proxy gateways may share the same proxyPath.";
      level = "cluster";
      severity = "error";
      tags = [
        "routing"
        "kix-examples"
      ];

      check =
        { allInstances, ... }:
        let
          # `allInstances` is `{ <ns> = { <name> = instance; }; }`.
          # Flatten into a list of { ns, name, inst } records.
          #
          # `lib.concatLists` is the nixpkgs equivalent of JS's
          # `arr.flat()` — flatten a list of lists into one list.
          # `builtins.attrNames` returns the keys of an attrset.
          flat = lib.concatLists (
            map (
              ns:
              map (name: {
                inherit ns name;
                inst = allInstances.${ns}.${name};
              }) (builtins.attrNames allInstances.${ns})
            ) (builtins.attrNames allInstances)
          );

          # Keep only reverse-proxy instances.
          proxies = builtins.filter (e: isProxy e.inst) flat;

          # Group by proxyPath → { "/v1/" = [...]; "/v2/" = [...]; }.
          byPath = builtins.foldl' (
            acc: e:
            let
              p = e.inst._meta.config.proxyPath or "?";
            in
            acc // { ${p} = (acc.${p} or [ ]) ++ [ e ]; }
          ) { } proxies;

          # Any path with more than one owner is a collision.
          collisions = lib.filterAttrs (_: members: builtins.length members > 1) byPath;
        in
        map (path: {
          message =
            "${toString (builtins.length collisions.${path})} reverse-proxy gateways share proxyPath '${path}': "
            + builtins.concatStringsSep ", " (
              map (e: "${e.ns}/${e.name}") collisions.${path}
            );
        }) (builtins.attrNames collisions);
    };
  };
}
