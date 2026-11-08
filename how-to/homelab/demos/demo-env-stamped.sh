#!/usr/bin/env bash
# demo-env-stamped.sh — Namespace-stamped environment boundary demo.
#
# Deploys two logical environments (dev + staging) on a single kind
# cluster via namespace prefixing. Same services (vaultwarden, filebrowser),
# different configs, independent namespaces.
#
# Then upgrades only the dev environment and shows that the blast radius
# is scoped entirely to dev-* namespaces — staging is untouched.
#
# This is the "namespace-prefixing / stamping" approach from the 90 doc
# (Bucket D): "same physical cluster, two logical envs. Exercises a
# different part of the DSL and validates that env boundaries don't
# have to be cluster boundaries."
#
# What this proves:
#   1. kix can render two independent service stacks in one cluster
#   2. Each env gets its own namespaces, PVCs, Ingresses, CNPs
#   3. Changing one env does NOT touch the other (blast radius scoped)
#   4. The DI graph is independent per env — no cross-env dependencies
#
# Phases:
#   Phase 0  bootstrap     — kind cluster + cilium
#   Phase 1  deploy        — kix deploy homelab-kind-env-stamped
#                            (dev-vaultwarden, dev-nas, staging-vaultwarden, staging-nas)
#   Phase 2  verify envs   — both envs running, independent namespaces
#   Phase 3  blast radius  — diff env-stamped vs env-stamped-dev-change
#                            (only dev-* namespaces in the diff)
#   Phase 4  upgrade dev   — kix deploy homelab-kind-env-stamped-dev-change
#   Phase 5  verify scope  — dev changed, staging untouched
#   Phase 6  rollback      — kix deploy homelab-kind-env-stamped (restore dev)
#
# Usage: ./how-to/homelab/demos/demo-env-stamped.sh [--keep] [--recreate] [--no-preload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-env"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true


for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --no-preload) PRELOAD=false ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
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
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

get_pvc_size() {
    local ns="$1" pvc_name="$2"
    kubectl --context "$KCTX" -n "$ns" get pvc "$pvc_name" \
        -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "?"
}

ns_exists() {
    kubectl --context "$KCTX" get namespace "$1" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — bootstrap kind cluster"
# ─────────────────────────────────────────────────────────────────────────

KIND_CONFIG="$(mktemp -t kix-homelab-env-kind.XXXXXX.yaml)"
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
    log "preloading images"
    mapfile -t IMAGES < <(kix --no-cache --flake . -q images homelab-kind-env-stamped 2>/dev/null) || IMAGES=()
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
phase "PHASE 1 — deploy env-stamped cluster (dev + staging)"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-env-stamped -y --tui --on-error continue \
    || warn "kix deploy reported errors (continuing)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — verify both environments running"
# ─────────────────────────────────────────────────────────────────────────

log "namespace check:"
for ns in dev-vaultwarden dev-nas staging-vaultwarden staging-nas; do
    if ns_exists "$ns"; then
        ok "namespace '$ns' exists"
    else
        fail "namespace '$ns' missing"
    fi
done
echo

# Wait for deployments in both envs.
for ns_deploy in "dev-vaultwarden:vaultwarden" "dev-nas:filebrowser" "staging-vaultwarden:vaultwarden" "staging-nas:filebrowser"; do
    ns="${ns_deploy%%:*}"
    deploy="${ns_deploy##*:}"
    kubectl --context "$KCTX" -n "$ns" rollout status "deployment/$deploy" --timeout=3m \
        || warn "$ns/$deploy not ready"
done

log "PVC comparison across environments:"
echo "  dev-vaultwarden/storage:     $(get_pvc_size dev-vaultwarden storage) (expect 512Mi)"
echo "  staging-vaultwarden/storage: $(get_pvc_size staging-vaultwarden storage) (expect 2Gi)"
echo "  dev-nas/storage:             $(get_pvc_size dev-nas storage) (expect 10Gi)"
echo "  staging-nas/storage:         $(get_pvc_size staging-nas storage) (expect 50Gi)"
echo

log "Ingresses across environments:"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

log "health check"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-env-stamped || warn "health flagged issues"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — blast radius: change ONLY dev environment"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-env-stamped homelab-kind-env-stamped-dev-change \
    "dev-only change: storage resize + domain switch"

# Check that staging namespaces are NOT in the diff.
ENV_BASE="$("$SCRIPT_DIR/render-manifests.sh" homelab-kind-env-stamped)"
ENV_DEV="$("$SCRIPT_DIR/render-manifests.sh" homelab-kind-env-stamped-dev-change)"
STAGING_DIFF="$(diff -rq "$ENV_BASE" "$ENV_DEV" 2>/dev/null | grep -c 'staging' || true)"

if [ "$STAGING_DIFF" -eq 0 ]; then
    ok "staging namespaces UNTOUCHED — blast radius correctly scoped to dev"
else
    fail "staging namespaces appear in the diff ($STAGING_DIFF lines) — env isolation broken"
fi
echo

log "kix diff homelab-kind-env-stamped-dev-change"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-env-stamped-dev-change 2>&1 | tail -40 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — deploy dev-only change"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-env-stamped-dev-change"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-env-stamped-dev-change -y --tui --on-error continue \
    || warn "dev-change deploy reported errors"

sleep 3

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — verify: dev changed, staging untouched"
# ─────────────────────────────────────────────────────────────────────────

log "post-upgrade PVC comparison:"
DEV_VAULT_SIZE="$(get_pvc_size dev-vaultwarden storage)"
STAGING_VAULT_SIZE="$(get_pvc_size staging-vaultwarden storage)"
DEV_NAS_SIZE="$(get_pvc_size dev-nas storage)"
STAGING_NAS_SIZE="$(get_pvc_size staging-nas storage)"

echo "  dev-vaultwarden/storage:     $DEV_VAULT_SIZE (expect 1Gi — was 512Mi)"
echo "  staging-vaultwarden/storage: $STAGING_VAULT_SIZE (expect 2Gi — unchanged)"
echo "  dev-nas/storage:             $DEV_NAS_SIZE (expect 20Gi — was 10Gi)"
echo "  staging-nas/storage:         $STAGING_NAS_SIZE (expect 50Gi — unchanged)"
echo

[ "$DEV_VAULT_SIZE" = "1Gi" ]       && ok "dev-vaultwarden resized: 1Gi"      || fail "dev-vaultwarden expected 1Gi, got $DEV_VAULT_SIZE"
[ "$STAGING_VAULT_SIZE" = "2Gi" ]   && ok "staging-vaultwarden unchanged: 2Gi" || fail "staging-vaultwarden expected 2Gi, got $STAGING_VAULT_SIZE"
[ "$DEV_NAS_SIZE" = "20Gi" ]        && ok "dev-nas resized: 20Gi"             || fail "dev-nas expected 20Gi, got $DEV_NAS_SIZE"
[ "$STAGING_NAS_SIZE" = "50Gi" ]    && ok "staging-nas unchanged: 50Gi"        || fail "staging-nas expected 50Gi, got $STAGING_NAS_SIZE"

log "Ingresses (dev should show homelab-v2.lan, staging still homelab.lan):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

log "health check after dev-only change"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-env-stamped-dev-change || warn "health flagged issues"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 6 — rollback to original env-stamped"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-env-stamped-dev-change homelab-kind-env-stamped \
    "rollback dev changes"

log "kix deploy homelab-kind-env-stamped (rolling back)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-env-stamped -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 3

log "post-rollback PVC sizes:"
echo "  dev-vaultwarden/storage:     $(get_pvc_size dev-vaultwarden storage) (expect 512Mi)"
echo "  staging-vaultwarden/storage: $(get_pvc_size staging-vaultwarden storage) (expect 2Gi)"
echo

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-env-stamped || warn "health flagged issues"

echo
echo -e "${M}═══ ENV-STAMPED SUMMARY ═══${N}"
echo -e "  Two logical environments on one physical cluster:"
echo -e "    dev-vaultwarden, dev-nas        → vault-dev.homelab.lan, files-dev.homelab.lan"
echo -e "    staging-vaultwarden, staging-nas → vault-staging.homelab.lan, files-staging.homelab.lan"
echo -e "  ${G}Changing dev does NOT touch staging, so the blast radius is env-scoped${N}"
echo

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "env-stamped demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "env-stamped demo finished with failures — see assertions above"
fi
