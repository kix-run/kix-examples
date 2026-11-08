#!/usr/bin/env bash
# Render a cluster's manifests into a directory and print the directory.
#
# The layout is one file per object, `<namespace>/<name>-<kind>.json`, with
# cluster-scoped objects under `_cluster/`. The demos diff two of these
# directories to count the objects a change touches.
#
# Plain `nix build .#cluster-<name>` cannot render a Helm chart, and the
# homelab clusters use Helm, so this script renders through `kix build`.
#
# usage: render-manifests.sh <cluster>
#
# Run it from the kix-examples root. Set KIX to the `kix` command to run
# (default: `kix` on PATH) and RENDER_DIR to change where the output goes.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    sed -n '11p' "$0" >&2
    exit 2
fi

cluster="$1"
out="${RENDER_DIR:-${TMPDIR:-/tmp}/kix-homelab-manifests}/$cluster"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

"${KIX:-kix}" --no-cache --flake . -q build -o json "$cluster" >"$tmp"

rm -rf "$out"
mkdir -p "$out"
python3 - "$tmp" "$out" <<'PY'
import json, os, sys

src, out = sys.argv[1], sys.argv[2]
for obj in json.load(open(src)):
    meta = obj.get("metadata", {})
    ns = meta.get("namespace") or "_cluster"
    name = f"{meta.get('name', 'unnamed')}-{obj.get('kind', 'Unknown').lower()}.json"
    os.makedirs(os.path.join(out, ns), exist_ok=True)
    with open(os.path.join(out, ns, name), "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
PY

echo "$out"
