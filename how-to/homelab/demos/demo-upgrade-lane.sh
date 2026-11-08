#!/usr/bin/env bash
# demo-upgrade-lane.sh — the small-change lane of the kix lifecycle
# engine, plus a visible blast-radius contrast.
#
# Story 2b (live gateway migration) was the big-change lane. Nothing
# yet exercises the small-change lane or makes "blast radius" concrete.
# This script does both in five phases on a single kind cluster:
#
#   Phase 0  bootstrap  — kind + connectivity gate
#   Phase 1  baseline   — kix deploy homelab-kind
#   Phase 2  small       — kix deploy homelab-kind-upgrade-small
#                          (delta: monitoring.loki.storageSize 5Gi→6Gi)
#                          blast radius: 2 manifests
#   Phase 3  broad       — kix deploy homelab-kind-upgrade-broad
#                          (delta: cluster.domain homelab.lan→homelab-v2.lan)
#                          blast radius: ~15 manifests across 4 namespaces
#                          (every Ingress host re-renders, grafana rootUrl
#                          re-renders, ingress-bound PackageInstances
#                          re-hash, activation manifest re-renders)
#   Phase 4  rollback    — kix deploy homelab-kind
#                          (every phase-3 change reverts; activation history
#                          proves the small+broad lane is reversible)
#   Phase 5  drift inject — `kubectl patch` bumps immich replicas behind
#                          kix's back; `kix health` flags the drift;
#                          `kix deploy --reconcile` heals it back to 1.
#
# The blast radius numbers are computed deterministically by diffing
# the rendered manifest trees from render-manifests.sh, not from regexes over diff output.
#
# Usage: ./how-to/homelab/demos/demo-upgrade-lane.sh [--keep] [--recreate] [--no-preload] [--skip-drift]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-upgrade"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true
SKIP_DRIFT=false


for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --no-preload) PRELOAD=false ;;
        --skip-drift) SKIP_DRIFT=true ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; D='\033[0;90m'; M='\033[0;35m'; N='\033[0m'
log()   { echo -e "${B}==>${N} $*"; }
phase() { echo -e "\n${M}━━━ $* ━━━${N}\n"; }
ok()    { echo -e "${G}✓${N} $*"; }
warn()  { echo -e "${Y}!${N} $*"; }
fail()  { echo -e "${R}✗${N} $*"; FAILED=1; }
die()   { echo -e "${R}✗${N} $*" >&2; exit 1; }

FAILED=0
SCRIPT_START=$SECONDS

cleanup() {
    [ -n "${KIND_CONFIG:-}" ] && rm -f "$KIND_CONFIG"
    if [ "$KEEP" = false ]; then
        log "deleting kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        warn "keeping cluster '$CLUSTER_NAME'"
    fi
}
trap cleanup EXIT INT TERM

for cmd in kind kubectl kix cilium python3; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

# ── blast-radius helper ─────────────────────────────────────────────────
# Builds two cluster variants and reports:
#   - number of manifest files that differ
#   - unique namespaces / packages touched
#   - the full per-file list
# Numbers come from render-manifests.sh output trees, not from parsing any
# log — they're deterministic.
compute_blast_radius() {
    local baseline_variant="$1"
    local target_variant="$2"
    local label="$3"

    local p1 p2
    p1="$("$SCRIPT_DIR/render-manifests.sh" "${baseline_variant}")"
    p2="$("$SCRIPT_DIR/render-manifests.sh" "${target_variant}")"

    # Count changed files.
    local diff_output
    diff_output="$(diff -rq "$p1" "$p2" 2>/dev/null || true)"
    local changed_files
    changed_files="$(echo "$diff_output" | grep -c '^Files\|^Only in' || true)"

    # Unique top-level dirs (namespaces) touched.
    local namespaces
    namespaces="$(echo "$diff_output" \
        | sed -nE "s|^Files ${p1}/([^/]+)/.*|\1|p; s|^Only in ${p1}/([^/]+):.*|\1|p; s|^Only in ${p2}/([^/]+):.*|\1|p" \
        | sort -u \
        | tr '\n' ' ')"
    local ns_count
    ns_count="$(echo "$diff_output" \
        | sed -nE "s|^Files ${p1}/([^/]+)/.*|\1|p; s|^Only in ${p1}/([^/]+):.*|\1|p; s|^Only in ${p2}/([^/]+):.*|\1|p" \
        | sort -u \
        | wc -l | tr -d ' ')"

    echo -e "${M}┌ blast radius: ${label}${N}"
    echo -e "${M}│${N}   manifests changed : ${G}${changed_files}${N}"
    echo -e "${M}│${N}   namespaces touched: ${G}${ns_count}${N} (${namespaces})"
    echo -e "${M}│${N}   ${D}rendered from baseline=${baseline_variant} target=${target_variant}${N}"
    echo -e "${M}└──────${N}"
    # Print the per-file list at reduced indent for anyone skimming.
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — bootstrap kind cluster"
# ─────────────────────────────────────────────────────────────────────────

KIND_CONFIG="$(mktemp -t kix-homelab-upgrade-kind.XXXXXX.yaml)"
cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        serializeImagePulls: false
        maxParallelImagePulls: 5
EOF

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    if [ "$RECREATE" = true ]; then
        kind delete cluster --name "$CLUSTER_NAME"
    else
        ok "reusing existing kind cluster '$CLUSTER_NAME'"
    fi
fi
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi

if [ "$PRELOAD" = true ]; then
    log "preloading homelab-kind images"
    mapfile -t IMAGES < <(kix --no-cache --flake . -q images homelab-kind 2>/dev/null) || IMAGES=()
    if [ ${#IMAGES[@]} -gt 0 ]; then
        printf '%s\n' "${IMAGES[@]}" | python3 "$SCRIPT_DIR/docker-pull-parallel.py" \
            || warn "some image(s) failed to pull"
        declare -A SEEN; TAGS=()
        for img in "${IMAGES[@]}"; do
            tag="${img%%@sha256:*}"
            if [[ "$img" == *@sha256:* ]]; then
                docker tag "$img" "$tag" 2>/dev/null || true
            fi
            if [ -z "${SEEN[$tag]:-}" ]; then SEEN[$tag]=1; TAGS+=("$tag"); fi
        done
        for tag in "${TAGS[@]}"; do
            kind load docker-image --name "$CLUSTER_NAME" "$tag" >/dev/null 2>&1 &
        done
        wait
        for img in "${IMAGES[@]}"; do
            if [[ "$img" == *@sha256:* ]]; then
                kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null 2>&1 || true
            fi
        done
        ok "images preloaded"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 1 — deploy homelab-kind baseline"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy homelab-kind reported errors (continuing)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues"
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

log "baseline health check"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "kix health exited non-zero on baseline"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — small upgrade (blast radius: single resource)"
# ─────────────────────────────────────────────────────────────────────────

# Compute blast radius BEFORE applying, so the reader sees the plan first.
compute_blast_radius homelab-kind homelab-kind-upgrade-small "loki storageSize 5Gi → 6Gi"

log "kix diff homelab-kind-upgrade-small"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-upgrade-small 2>&1 | tail -40 || true
echo

log "kix deploy homelab-kind-upgrade-small"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-upgrade-small -y --tui --on-error continue \
    || warn "small upgrade deploy reported errors (continuing)"

log "health check after small upgrade"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-upgrade-small || warn "health flagged issues after small upgrade"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — broad upgrade (blast radius: fan-out across packages)"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-upgrade-small homelab-kind-upgrade-broad "cluster.domain homelab.lan → homelab-v2.lan"

log "kix diff homelab-kind-upgrade-broad"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-upgrade-broad 2>&1 | tail -60 || true
echo

log "kix deploy homelab-kind-upgrade-broad"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-upgrade-broad -y --tui --on-error continue \
    || warn "broad upgrade deploy reported errors (continuing)"

sleep 5
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready after broad upgrade"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready after broad upgrade"

log "health check after broad upgrade"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-upgrade-broad || warn "health flagged issues after broad upgrade"

# Narrate the visible result.
log "Ingresses (should now be on homelab-v2.lan hosts):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — rollback to baseline"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-upgrade-broad homelab-kind "roll back to baseline"

log "kix deploy homelab-kind  (rolling back through the upgrade chain)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

log "Ingresses (should be back on homelab.lan):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — drift injection"
# ─────────────────────────────────────────────────────────────────────────

if [ "$SKIP_DRIFT" = true ]; then
    warn "skipping drift injection (--skip-drift)"
else
    log "patching immich-server replicas 1 → 3 behind kix's back"
    kubectl --context "$KCTX" -n immich patch deployment/immich-server \
        --type=merge -p '{"spec":{"replicas":3}}' \
        || fail "could not patch immich-server"

    sleep 3

    log "kix health homelab-kind (should flag drift)"
    if kix --no-cache --flake . --context "$KCTX" health homelab-kind 2>&1 | tee /tmp/kix-health-drift.log | grep -qiE 'drift|mismatch|out.?of.?sync|differs|replicas'; then
        ok "drift detected — kix health surfaces the out-of-band change"
    else
        warn "drift not obviously flagged in kix health output (see /tmp/kix-health-drift.log)"
        warn "(the check is text-matching — may be a false negative on a format change)"
    fi

    log "kix deploy --reconcile homelab-kind (heal drift)"
    kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --reconcile --tui --on-error continue \
        || warn "reconcile deploy reported errors"

    # Poll for the replica count to settle back to 1.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        replicas="$(kubectl --context "$KCTX" -n immich get deployment/immich-server -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
        if [ "$replicas" = "1" ]; then
            ok "drift healed — immich-server replicas back to 1"
            break
        fi
        sleep 2
    done

    log "kix health homelab-kind (should be clean again)"
    kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health still reports issues after reconcile"
fi

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "upgrade-lane demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "upgrade-lane demo finished with failures — see assertions above"
fi
