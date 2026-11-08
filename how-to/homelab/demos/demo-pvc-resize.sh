#!/usr/bin/env bash
# demo-pvc-resize.sh — PVC resize migration demo.
#
# The simplest stateful migration: change PVC sizes on a running cluster.
# No data movement, no operator swap — just spec.resources.requests.storage
# changes on existing PVCs.
#
# Phases:
#   Phase 0  bootstrap   — kind cluster + cilium
#   Phase 1  baseline    — kix deploy homelab-kind
#   Phase 2  blast radius — deterministic diff of rendered trees
#   Phase 3  resize      — kix deploy homelab-kind-pvc-resize
#                           (immich 100→200Gi, nas 200→300Gi, vaultwarden 1→2Gi)
#   Phase 4  verify      — PVC specs reflect new sizes, workloads healthy
#   Phase 5  rollback    — kix deploy homelab-kind, verify sizes revert
#
# In real K8s, PVC resize requires allowVolumeExpansion on the StorageClass.
# On kind's ephemeral "standard" class there's no real volume — the demo
# value is in what kix diff reports and how the DI graph re-hashes.
#
# Usage: ./how-to/homelab/demos/demo-pvc-resize.sh [--keep] [--recreate] [--no-preload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-migrate"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true


for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --no-preload) PRELOAD=false ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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

# ── blast-radius helper (same as demo-upgrade-lane.sh) ─────────────────
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
    echo -e "${M}│${N}   ${D}rendered from baseline=${baseline_variant} target=${target_variant}${N}"
    echo -e "${M}└──────${N}"
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

# ── PVC size extractor ─────────────────────────────────────────────────
# Reads spec.resources.requests.storage from a PVC on the cluster.
get_pvc_size() {
    local ns="$1" pvc_name="$2"
    kubectl --context "$KCTX" -n "$ns" get pvc "$pvc_name" \
        -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "?"
}

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — bootstrap kind cluster"
# ─────────────────────────────────────────────────────────────────────────

KIND_CONFIG="$(mktemp -t kix-homelab-migrate-kind.XXXXXX.yaml)"
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

log "baseline PVC sizes:"
echo "  immich/storage:      $(get_pvc_size immich storage)"
echo "  nas/storage:         $(get_pvc_size nas storage)"
echo "  vaultwarden/storage: $(get_pvc_size vaultwarden storage)"
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — blast radius: PVC resize"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-pvc-resize \
    "PVC resize: immich 100→200Gi, nas 200→300Gi, vaultwarden 1→2Gi"

log "kix diff homelab-kind-pvc-resize"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-pvc-resize 2>&1 | tail -40 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — deploy PVC resize"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-pvc-resize"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-pvc-resize -y --tui --on-error continue \
    || warn "pvc-resize deploy reported errors (continuing)"

sleep 3
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — verify PVC sizes changed"
# ─────────────────────────────────────────────────────────────────────────

log "post-resize PVC sizes:"
IMMICH_SIZE="$(get_pvc_size immich storage)"
NAS_SIZE="$(get_pvc_size nas storage)"
VAULT_SIZE="$(get_pvc_size vaultwarden storage)"
echo "  immich/storage:      $IMMICH_SIZE"
echo "  nas/storage:         $NAS_SIZE"
echo "  vaultwarden/storage: $VAULT_SIZE"
echo

# Assert expected sizes.
[ "$IMMICH_SIZE" = "200Gi" ] && ok "immich storage: 200Gi" || fail "immich storage expected 200Gi, got $IMMICH_SIZE"
[ "$NAS_SIZE" = "300Gi" ]    && ok "nas storage: 300Gi"    || fail "nas storage expected 300Gi, got $NAS_SIZE"
[ "$VAULT_SIZE" = "2Gi" ]    && ok "vaultwarden storage: 2Gi" || fail "vaultwarden storage expected 2Gi, got $VAULT_SIZE"

log "health check after resize"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-pvc-resize || warn "health flagged issues after resize"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback to baseline"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-pvc-resize homelab-kind "rollback PVC sizes"

log "kix deploy homelab-kind (rolling back)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 3

log "post-rollback PVC sizes:"
IMMICH_SIZE="$(get_pvc_size immich storage)"
NAS_SIZE="$(get_pvc_size nas storage)"
VAULT_SIZE="$(get_pvc_size vaultwarden storage)"
echo "  immich/storage:      $IMMICH_SIZE"
echo "  nas/storage:         $NAS_SIZE"
echo "  vaultwarden/storage: $VAULT_SIZE"
echo

# NOTE: In real K8s, PVC *shrink* is not allowed — only expansion.
# On kind, the spec updates freely because there's no real provisioner
# enforcement. In a production scenario, rolling back a PVC resize
# would require the backup→delete→recreate→restore path. The demo
# still runs the rollback to show the manifest diff is symmetric.
[ "$IMMICH_SIZE" = "100Gi" ] && ok "immich storage rolled back: 100Gi" || warn "immich storage is $IMMICH_SIZE (shrink may be blocked on real storage)"
[ "$NAS_SIZE" = "200Gi" ]    && ok "nas storage rolled back: 200Gi"    || warn "nas storage is $NAS_SIZE (shrink may be blocked on real storage)"
[ "$VAULT_SIZE" = "1Gi" ]    && ok "vaultwarden storage rolled back: 1Gi" || warn "vaultwarden storage is $VAULT_SIZE (shrink may be blocked on real storage)"

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "PVC resize migration demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "PVC resize demo finished with failures — see assertions above"
fi
