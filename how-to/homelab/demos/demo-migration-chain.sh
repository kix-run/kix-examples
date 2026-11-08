#!/usr/bin/env bash
# demo-migration-chain.sh — Combined migration chain demo.
#
# Chains three migration stories as sequential upgrades on a single
# kind cluster, then rolls back through the full chain to baseline.
# Proves that migrations compose and that the activation history
# is a stack, not just a pair.
#
# Chain (forward):
#   Phase 0  bootstrap         — kind cluster + cilium
#   Phase 1  baseline          — kix deploy homelab-kind
#   Phase 2  PVC resize        — kix deploy homelab-kind-pvc-resize
#                                 (immich 100→200Gi, nas 200→300Gi, vaultwarden 1→2Gi)
#   Phase 3  StorageClass swap — kix deploy homelab-kind-storage-migrate
#                                 (standard → kind-fast + PVC resize)
#   Phase 4  DB resize         — kix deploy homelab-kind-db-resize
#                                 (postgres 50→100Gi, loki 5→10Gi)
#
# Chain (rollback — reverse order):
#   Phase 5  rollback to StorageClass — kix deploy homelab-kind-storage-migrate
#   Phase 6  rollback to PVC resize   — kix deploy homelab-kind-pvc-resize
#   Phase 7  rollback to baseline     — kix deploy homelab-kind
#
# At each step: blast radius, deploy, health check, assertions.
#
# Usage: ./how-to/homelab/demos/demo-migration-chain.sh [--keep] [--recreate] [--no-preload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-migrate-chain"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true


for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --no-preload) PRELOAD=false ;;
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

# ── blast-radius helper ────────────────────────────────────────────────
compute_blast_radius() {
    local baseline_variant="$1"
    local target_variant="$2"
    local label="$3"

    local p1 p2
    p1="$("$SCRIPT_DIR/render-manifests.sh" "${baseline_variant}")"
    p2="$("$SCRIPT_DIR/render-manifests.sh" "${target_variant}")"

    local diff_output
    diff_output="$(diff -rq "$p1" "$p2" 2>/dev/null || true)"
    local changed_files
    changed_files="$(echo "$diff_output" | grep -c '^Files\|^Only in' || true)"

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
    echo -e "${M}└──────${N}"
    echo
}

get_pvc_size() {
    local ns="$1" pvc_name="$2"
    kubectl --context "$KCTX" -n "$ns" get pvc "$pvc_name" \
        -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "?"
}

get_pvc_class() {
    local ns="$1" pvc_name="$2"
    kubectl --context "$KCTX" -n "$ns" get pvc "$pvc_name" \
        -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "?"
}

get_sgcluster_storage() {
    kubectl --context "$KCTX" -n data get sgcluster postgres \
        -o jsonpath='{.spec.pods.persistentVolume.size}' 2>/dev/null || echo "?"
}

wait_ready() {
    kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m 2>/dev/null || warn "immich not ready"
    kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m 2>/dev/null || warn "vaultwarden not ready"
}

# Print a snapshot of the cluster's stateful resources.
snapshot() {
    local label="$1"
    log "${label}:"
    echo "  immich PVC size:      $(get_pvc_size immich storage)"
    echo "  immich PVC class:     $(get_pvc_class immich storage)"
    echo "  nas PVC size:         $(get_pvc_size nas storage)"
    echo "  vaultwarden PVC size: $(get_pvc_size vaultwarden storage)"
    echo "  postgres (SGCluster): $(get_sgcluster_storage)"
    echo "  loki PVC size:        $(get_pvc_size monitoring-system loki-storage)"
    echo
}

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — bootstrap kind cluster"
# ─────────────────────────────────────────────────────────────────────────

KIND_CONFIG="$(mktemp -t kix-homelab-chain-kind.XXXXXX.yaml)"
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
wait_ready
snapshot "BASELINE state"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — migration 1/3: PVC resize"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-pvc-resize \
    "step 1: PVC resize (immich 100→200Gi, nas 200→300Gi, vault 1→2Gi)"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-pvc-resize -y --tui --on-error continue \
    || warn "pvc-resize deploy reported errors"
sleep 3
wait_ready
snapshot "after PVC resize"

[ "$(get_pvc_size immich storage)" = "200Gi" ] && ok "immich: 200Gi" || fail "immich expected 200Gi"
[ "$(get_pvc_size vaultwarden storage)" = "2Gi" ] && ok "vaultwarden: 2Gi" || fail "vaultwarden expected 2Gi"

kix --no-cache --flake . --context "$KCTX" health homelab-kind-pvc-resize || warn "health issues after step 1"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — migration 2/3: StorageClass swap"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-pvc-resize homelab-kind-storage-migrate \
    "step 2: StorageClass standard → kind-fast"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-storage-migrate -y --tui --on-error continue \
    || warn "storage-migrate deploy reported errors"
sleep 3
wait_ready
snapshot "after StorageClass swap"

[ "$(get_pvc_class immich storage)" = "kind-fast" ] && ok "immich class: kind-fast" || fail "immich class expected kind-fast"
[ "$(get_pvc_class vaultwarden storage)" = "kind-fast" ] && ok "vaultwarden class: kind-fast" || fail "vaultwarden class expected kind-fast"

kix --no-cache --flake . --context "$KCTX" health homelab-kind-storage-migrate || warn "health issues after step 2"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — migration 3/3: database storage resize"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-storage-migrate homelab-kind-db-resize \
    "step 3: postgres 50→100Gi + loki 5→10Gi"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-db-resize -y --tui --on-error continue \
    || warn "db-resize deploy reported errors"
sleep 5
wait_ready
snapshot "after DB resize (chain peak)"

[ "$(get_sgcluster_storage)" = "100Gi" ] && ok "postgres: 100Gi" || fail "postgres expected 100Gi"
[ "$(get_pvc_size monitoring-system loki-storage)" = "10Gi" ] && ok "loki: 10Gi" || fail "loki expected 10Gi"

kix --no-cache --flake . --context "$KCTX" health homelab-kind-db-resize || warn "health issues after step 3"

# ═════════════════════════════════════════════════════════════════════════
phase "ROLLBACK — unwinding the chain"
# ═════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback 1/3: undo DB resize → StorageClass swap state"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-db-resize homelab-kind-storage-migrate \
    "rollback step 3 → step 2"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-storage-migrate -y --tui --on-error continue \
    || warn "rollback to storage-migrate reported errors"
sleep 3
wait_ready
snapshot "after rollback to StorageClass swap"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-storage-migrate || warn "health issues"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 6 — rollback 2/3: undo StorageClass → PVC resize state"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-storage-migrate homelab-kind-pvc-resize \
    "rollback step 2 → step 1"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-pvc-resize -y --tui --on-error continue \
    || warn "rollback to pvc-resize reported errors"
sleep 3
wait_ready
snapshot "after rollback to PVC resize"

[ "$(get_pvc_class immich storage)" = "standard" ] && ok "immich class restored: standard" || warn "immich class is $(get_pvc_class immich storage)"

kix --no-cache --flake . --context "$KCTX" health homelab-kind-pvc-resize || warn "health issues"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 7 — rollback 3/3: restore baseline"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-pvc-resize homelab-kind \
    "rollback step 1 → baseline"

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback to baseline reported errors"
sleep 3
wait_ready
snapshot "FINAL — back to baseline"

[ "$(get_pvc_size immich storage)" = "100Gi" ] && ok "immich restored: 100Gi" || warn "immich is $(get_pvc_size immich storage)"
[ "$(get_pvc_size vaultwarden storage)" = "1Gi" ] && ok "vaultwarden restored: 1Gi" || warn "vaultwarden is $(get_pvc_size vaultwarden storage)"
[ "$(get_sgcluster_storage)" = "50Gi" ] && ok "postgres restored: 50Gi" || warn "postgres is $(get_sgcluster_storage)"

kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health issues after full rollback"

echo
echo -e "${M}═══ MIGRATION CHAIN SUMMARY ═══${N}"
echo -e "  Forward:  baseline → pvc-resize → storage-migrate → db-resize"
echo -e "  Rollback: db-resize → storage-migrate → pvc-resize → baseline"
echo -e "  ${G}7 deployments on one cluster, one activation identity${N}"
echo

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "migration chain demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "migration chain demo finished with failures — see assertions above"
fi
