# scorecard.nix — the rules wired into cluster.nix.
#
# Recommended reading: 10-reuse-packages (`noProxyPathCollision`
# only makes sense when there's more than one proxy in the cluster).
#
# Three rules, each at a different scope:
#
#   reliability                       — whole built-in category
#   proxyMaxBodySizeMustBeExplicit    — custom, package-level
#   noProxyPathCollision              — custom, cluster-level
#
# This file is a function `{ lib, kix }: { ... }` so it can use
# `kix.rules.*` and `lib.*`. cluster.nix imports it and stays focused
# on the cluster shape.

{ lib, kix }:

let
  # Reverse-proxy instances declare themselves via
  # `meta.provides = [ "reverse-proxy" ]` (see ./reverse-proxy-package.nix).
  # That's the canonical way Kix packages advertise their capability,
  # used throughout kixpkgs (`[ "sql-database" ]`, `[ "reflection" ]`,
  # `[ "vpn" ]`, etc.). Matching by capability rather than by name or
  # description means the rule keeps working through renames.
  # region:isProxy
  isProxy =
    inst:
    # Cluster-level rules inspect built instances, so the package
    # metadata is under `inst._meta.packageMeta`.
    builtins.elem "reverse-proxy" (inst._meta.packageMeta.provides or [ ]);
  # endregion:isProxy
in
# region:scorecardStructure
{
  enable = true;

  # Per-rule severity override. Key is `<category>.<rule>`.
  # Raises a built-in from "warning" to "error" so the build fails
  # if a probe is missing.
  ruleOverrides.byRule."reliability.hasProbes".severity = "error";

  rules = {
    # 1. Whole built-in category. Bundles hasProbes,
    #    boundedResources, hasResourceLimits, hasResourceRequests,
    #    gracefulShutdown, hasPDB.
    reliability = kix.rules.reliability;

    # region:customRules
    # 2. Custom package-level rule. Runs once per instance, with
    #    access to that instance's resolved `config` and `resources`.
    # region:packageRule
    custom.proxyMaxBodySizeMustBeExplicit = {
      description = "Reverse-proxy gateways must set maxBodySize explicitly (not the 1m default).";
      level = "package";
      severity = "error";
      tags = [ "reliability" "kix-examples" ];

      # Only run on reverse-proxy packages. `appliesTo` receives the
      # package metadata directly, so this checks `meta.provides`.
      appliesTo =
        { meta, ... }:
        builtins.elem "reverse-proxy" (meta.provides or [ ]);

      check =
        { config, instanceName, ... }:
        if (config.maxBodySize or "") == "1m" then
          [
            {
              message =
                "instance '${instanceName}' uses the default maxBodySize '1m'. "
                + "nginx rejects larger request bodies — set this explicitly.";
            }
          ]
        else
          [ ];
    };
    # endregion:packageRule

    # 3. Custom cluster-level rule. Sees `allInstances` across every
    #    namespace, so it can compare one instance with another.
    # region:clusterRule
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
    # endregion:clusterRule
    # endregion:customRules
  };
}
# endregion:scorecardStructure
