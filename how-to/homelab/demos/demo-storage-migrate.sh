#!/usr/bin/env bash
# demo-storage-migrate.sh — StorageClass migration demo.
#
# The first real migration pair: switch all PVCs from kind's default
# "standard" StorageClass to a custom "kind-fast" class (simulating
# local-path → zpool from 90 doc bucket A).
#
# In real K8s, changing spec.storageClassName on a bound PVC is
# FORBIDDEN — the API server rejects it outright. This is the
# migration that forces the "backup → delete old PVC → create new PVC
# → restore" path and motivates the backup contract from L2.
#
# On kind the PVCs are ephemeral (no real binding), so the manifests
# apply cleanly. The demo value is in:
#   1. What kix diff reports (every PVC + its consumers change)
#   2. The blast radius — how a single platform-level input
#      (storageClassName) fans out through the DI graph
#   3. The explicit WARNING that this is a destructive operation
#      on real storage
#
# Phases:
#   Phase 0  bootstrap   — kind cluster + cilium
#   Phase 1  baseline    — kix deploy homelab-kind
#   Phase 2  blast radius — deterministic diff of rendered trees
#   Phase 3  migrate     — kix deploy homelab-kind-storage-migrate
#   Phase 4  verify      — PVCs show new storageClassName, workloads healthy
#   Phase 5  rollback    — kix deploy homelab-kind, verify class reverts
#
# Usage: ./how-to/homelab/demos/demo-storage-migrate.sh [--keep] [--recreate] [--no-preload]

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
    echo -e "${M}│${N}   ${D}rendered from baseline=${baseline_variant} target=${target_variant}${N}"
    echo -e "${M}└──────${N}"
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

get_pvc_class() {
    local ns="$1" pvc_name="$2"
    kubectl --context "$KCTX" -n "$ns" get pvc "$pvc_name" \
        -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "?"
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

log "baseline StorageClass on PVCs:"
echo "  immich/storage:      $(get_pvc_class immich storage)"
echo "  nas/storage:         $(get_pvc_class nas storage)"
echo "  vaultwarden/storage: $(get_pvc_class vaultwarden storage)"
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — blast radius: StorageClass migration"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-storage-migrate \
    "StorageClass: standard → kind-fast + PVC resize"

echo -e "${Y}⚠  WARNING: On real storage, changing storageClassName on a bound PVC${N}"
echo -e "${Y}   is rejected by the K8s API server. This migration requires:${N}"
echo -e "${Y}   1. Backup data from old PVC${N}"
echo -e "${Y}   2. Delete old PVC${N}"
echo -e "${Y}   3. Create new PVC with new StorageClass${N}"
echo -e "${Y}   4. Restore data to new PVC${N}"
echo -e "${Y}   On kind, PVCs are ephemeral — the manifests apply directly.${N}"
echo

log "kix diff homelab-kind-storage-migrate"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-storage-migrate 2>&1 | tail -60 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — deploy StorageClass migration"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-storage-migrate"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-storage-migrate -y --tui --on-error continue \
    || warn "storage-migrate deploy reported errors (continuing)"

sleep 3
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — verify StorageClass changed"
# ─────────────────────────────────────────────────────────────────────────

log "post-migration StorageClass on PVCs:"
IMMICH_CLASS="$(get_pvc_class immich storage)"
NAS_CLASS="$(get_pvc_class nas storage)"
VAULT_CLASS="$(get_pvc_class vaultwarden storage)"
echo "  immich/storage:      $IMMICH_CLASS"
echo "  nas/storage:         $NAS_CLASS"
echo "  vaultwarden/storage: $VAULT_CLASS"
echo

[ "$IMMICH_CLASS" = "kind-fast" ] && ok "immich storage: kind-fast" || fail "immich storage expected kind-fast, got $IMMICH_CLASS"
[ "$NAS_CLASS" = "kind-fast" ]    && ok "nas storage: kind-fast"    || fail "nas storage expected kind-fast, got $NAS_CLASS"
[ "$VAULT_CLASS" = "kind-fast" ]  && ok "vaultwarden storage: kind-fast" || fail "vaultwarden storage expected kind-fast, got $VAULT_CLASS"

log "health check after migration"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-storage-migrate || warn "health flagged issues after migration"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback to baseline"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-storage-migrate homelab-kind "rollback StorageClass"

log "kix deploy homelab-kind (rolling back)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 3

log "post-rollback StorageClass on PVCs:"
IMMICH_CLASS="$(get_pvc_class immich storage)"
NAS_CLASS="$(get_pvc_class nas storage)"
VAULT_CLASS="$(get_pvc_class vaultwarden storage)"
echo "  immich/storage:      $IMMICH_CLASS"
echo "  nas/storage:         $NAS_CLASS"
echo "  vaultwarden/storage: $VAULT_CLASS"
echo

[ "$IMMICH_CLASS" = "standard" ] && ok "immich storage rolled back: standard" || warn "immich storage is $IMMICH_CLASS (class switch may need PVC recreate on real storage)"
[ "$NAS_CLASS" = "standard" ]    && ok "nas storage rolled back: standard"    || warn "nas storage is $NAS_CLASS"
[ "$VAULT_CLASS" = "standard" ]  && ok "vaultwarden storage rolled back: standard" || warn "vaultwarden storage is $VAULT_CLASS"

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "StorageClass migration demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "StorageClass migration demo finished with failures — see assertions above"
fi
