#!/usr/bin/env bash
# demo-ns-rename.sh — Namespace rename migration demo.
#
# The most destructive migration in the set: rename the `nas` namespace
# to `filebrowser`. In Kubernetes, namespace rename is IMPOSSIBLE —
# namespaces are immutable identifiers. The effect:
#
#   - All resources in `nas/` are PRUNED (old namespace, gone from desired state)
#   - All resources in `filebrowser/` are CREATED (new namespace)
#   - Stateful resources (the NAS PVC) lose data unless explicitly migrated
#
# This is the story that motivates the `moved {}` DSL primitive from
# ROADMAP line 142. The compiler CAN see that the package instance config
# is identical — only the namespace changed. A future `moved {}` would
# let the user express "this is the same workload, just renamed" and the
# lifecycle engine could orchestrate backup→delete→create→restore.
#
# Phases:
#   Phase 0  bootstrap   — kind cluster + cilium
#   Phase 1  baseline    — kix deploy homelab-kind (nas namespace exists)
#   Phase 2  blast radius — show the full namespace teardown + recreate
#   Phase 3  rename      — kix deploy homelab-kind-ns-rename
#   Phase 4  verify      — nas namespace gone, filebrowser namespace up
#   Phase 5  rollback    — kix deploy homelab-kind, nas restored
#
# Usage: ./how-to/homelab/demos/demo-ns-rename.sh [--keep] [--recreate] [--no-preload]

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
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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

    # For namespace renames, also show the PRUNE vs CREATE breakdown.
    local only_baseline only_target
    only_baseline="$(echo "$diff_output" | grep -c "^Only in ${p1}" || true)"
    only_target="$(echo "$diff_output" | grep -c "^Only in ${p2}" || true)"
    local modified
    modified="$(echo "$diff_output" | grep -c '^Files' || true)"

    echo -e "${M}┌ blast radius: ${label}${N}"
    echo -e "${M}│${N}   manifests changed : ${G}${changed_files}${N} (${R}${only_baseline} pruned${N}, ${G}${only_target} created${N}, ${Y}${modified} modified${N})"
    echo -e "${M}│${N}   namespaces touched: ${G}${ns_count}${N} (${namespaces})"
    echo -e "${M}│${N}   ${D}rendered from baseline=${baseline_variant} target=${target_variant}${N}"
    echo -e "${M}└──────${N}"
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

ns_exists() {
    kubectl --context "$KCTX" get namespace "$1" >/dev/null 2>&1
}

count_resources_in_ns() {
    kubectl --context "$KCTX" -n "$1" get all --no-headers 2>/dev/null | wc -l | tr -d ' '
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

log "baseline namespace state:"
ns_exists nas         && ok "namespace 'nas' exists ($(count_resources_in_ns nas) resources)" \
                      || fail "namespace 'nas' should exist in baseline"
ns_exists filebrowser && fail "namespace 'filebrowser' should NOT exist in baseline" \
                      || ok "namespace 'filebrowser' does not exist (expected)"
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — blast radius: namespace rename nas → filebrowser"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-ns-rename \
    "namespace rename: nas → filebrowser"

echo -e "${R}⚠  DESTRUCTIVE MIGRATION: Namespace rename is impossible in K8s.${N}"
echo -e "${R}   Effect: all resources in 'nas/' are PRUNED, all in 'filebrowser/' are CREATED.${N}"
echo -e "${R}   Stateful resources (PVCs) lose data unless explicitly migrated.${N}"
echo -e "${R}   This is the case that motivates the 'moved {}' DSL primitive.${N}"
echo

log "kix diff homelab-kind-ns-rename"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-ns-rename 2>&1 | tail -60 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — deploy namespace rename"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-ns-rename"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-ns-rename -y --tui --on-error continue \
    || warn "ns-rename deploy reported errors (continuing)"

sleep 5

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — verify namespace rename"
# ─────────────────────────────────────────────────────────────────────────

log "post-rename namespace state:"
ns_exists filebrowser && ok "namespace 'filebrowser' exists ($(count_resources_in_ns filebrowser) resources)" \
                      || fail "namespace 'filebrowser' should exist after rename"

# Check that filebrowser workloads are running.
if kubectl --context "$KCTX" -n filebrowser get deployment filebrowser -o name >/dev/null 2>&1; then
    ok "filebrowser deployment exists in new namespace"
    kubectl --context "$KCTX" -n filebrowser rollout status deployment/filebrowser --timeout=3m \
        || warn "filebrowser not ready in new namespace"
else
    fail "filebrowser deployment missing in new namespace"
fi

# Check PVC exists in new namespace.
if kubectl --context "$KCTX" -n filebrowser get pvc storage -o name >/dev/null 2>&1; then
    ok "PVC 'storage' exists in namespace 'filebrowser'"
else
    fail "PVC 'storage' missing in namespace 'filebrowser'"
fi

# The old namespace may still exist (K8s doesn't auto-delete namespaces
# when all resources are pruned), but it should be empty.
if ns_exists nas; then
    NAS_RESOURCES="$(count_resources_in_ns nas)"
    if [ "$NAS_RESOURCES" -eq 0 ]; then
        ok "namespace 'nas' is empty (resources pruned, namespace lingers)"
    else
        warn "namespace 'nas' still has $NAS_RESOURCES resources"
    fi
else
    ok "namespace 'nas' fully removed"
fi

log "health check after rename"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-ns-rename || warn "health flagged issues after rename"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback to baseline (restore nas namespace)"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-ns-rename homelab-kind "rollback namespace rename"

log "kix deploy homelab-kind (rolling back)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 5

log "post-rollback namespace state:"
ns_exists nas         && ok "namespace 'nas' restored ($(count_resources_in_ns nas) resources)" \
                      || fail "namespace 'nas' should be restored after rollback"

# Verify filebrowser workloads moved back to nas.
if kubectl --context "$KCTX" -n nas get deployment filebrowser -o name >/dev/null 2>&1; then
    ok "filebrowser deployment back in 'nas' namespace"
else
    fail "filebrowser deployment missing in 'nas' after rollback"
fi

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "namespace rename migration demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "namespace rename demo finished with failures — see assertions above"
fi
