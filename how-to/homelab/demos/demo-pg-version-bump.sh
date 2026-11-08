#!/usr/bin/env bash
# demo-pg-version-bump.sh — Postgres major version bump demo.
#
# Upgrades StackGres postgres from version 16 → 17 on a running cluster.
# This is the smallest operator-managed migration that changes the
# database engine itself (not just storage sizing).
#
# What changes:
#   - SGCluster spec.postgres.version: "16" → "17"
#   - SGPostgresConfig name: postgres-pg16-config → postgres-pg17-config
#     (PRUNE old + CREATE new — a rename in the operator's config space)
#   - Patroni container image tag: pg16 → pg17
#   - Bootstrap job, reflect job, all consumer hashes cascade
#
# This is the stepping stone to the "hardest migration pair" (L6:
# Stackgres → CNPG) — it exercises operator CR changes without
# swapping the operator itself.
#
# Phases:
#   Phase 0  bootstrap   — kind cluster + cilium
#   Phase 1  baseline    — kix deploy homelab-kind (postgres 16)
#   Phase 2  blast radius — SGPostgresConfig rename + cascade
#   Phase 3  upgrade     — kix deploy homelab-kind-pg17
#   Phase 4  verify      — SGCluster reflects version 17
#   Phase 5  rollback    — kix deploy homelab-kind (back to postgres 16)
#
# Usage: ./how-to/homelab/demos/demo-pg-version-bump.sh [--keep] [--recreate] [--no-preload]

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

    local only_baseline only_target modified
    only_baseline="$(echo "$diff_output" | grep -c "^Only in ${p1}" || true)"
    only_target="$(echo "$diff_output" | grep -c "^Only in ${p2}" || true)"
    modified="$(echo "$diff_output" | grep -c '^Files' || true)"

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
    echo -e "${M}│${N}   manifests changed : ${G}${changed_files}${N} (${R}${only_baseline} pruned${N}, ${G}${only_target} created${N}, ${Y}${modified} modified${N})"
    echo -e "${M}│${N}   namespaces touched: ${G}${ns_count}${N} (${namespaces})"
    echo -e "${M}└──────${N}"
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |"
    echo
}

get_pg_version() {
    kubectl --context "$KCTX" -n data get sgcluster postgres \
        -o jsonpath='{.spec.postgres.version}' 2>/dev/null || echo "?"
}

get_pg_config_name() {
    kubectl --context "$KCTX" -n data get sgpostgresconfig \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "?"
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
phase "PHASE 1 — deploy homelab-kind baseline (Postgres 16)"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy homelab-kind reported errors (continuing)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues"
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

log "baseline state:"
echo "  SGCluster postgres.version: $(get_pg_version)"
echo "  SGPostgresConfig:           $(get_pg_config_name)"
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — blast radius: Postgres 16 → 17"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-pg17 \
    "Postgres 16 → 17 (SGPostgresConfig rename + cascade)"

echo -e "${Y}⚠  NOTE: A Postgres major version bump is a significant migration:${N}"
echo -e "${Y}   - SGPostgresConfig is RENAMED (pg16 → pg17) = PRUNE + CREATE${N}"
echo -e "${Y}   - Patroni image changes to pg17 build${N}"
echo -e "${Y}   - On real clusters, StackGres may require a rolling restart${N}"
echo -e "${Y}     or pg_upgrade depending on operator version${N}"
echo -e "${Y}   - On kind, CRDs may not be installed — kix diff/deploy still${N}"
echo -e "${Y}     shows the correct manifest changes${N}"
echo

log "kix diff homelab-kind-pg17"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-pg17 2>&1 | tail -40 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — deploy Postgres 17 upgrade"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-pg17"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-pg17 -y --tui --on-error continue \
    || warn "pg17 deploy reported errors (continuing)"

sleep 5

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — verify Postgres version"
# ─────────────────────────────────────────────────────────────────────────

PG_VER="$(get_pg_version)"
PG_CFG="$(get_pg_config_name)"
log "post-upgrade state:"
echo "  SGCluster postgres.version: $PG_VER"
echo "  SGPostgresConfig:           $PG_CFG"
echo

[ "$PG_VER" = "17" ]                  && ok "postgres version: 17"                  || warn "postgres version is $PG_VER (SGCluster CRD may not be installed)"
[[ "$PG_CFG" == *pg17* ]]             && ok "SGPostgresConfig: pg17 variant"         || warn "SGPostgresConfig is $PG_CFG (expected pg17 variant)"

log "health check after version bump"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-pg17 || warn "health flagged issues after version bump"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback to Postgres 16"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-pg17 homelab-kind "rollback Postgres 17 → 16"

log "kix deploy homelab-kind (rolling back)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 5

PG_VER="$(get_pg_version)"
PG_CFG="$(get_pg_config_name)"
log "post-rollback state:"
echo "  SGCluster postgres.version: $PG_VER"
echo "  SGPostgresConfig:           $PG_CFG"
echo

[ "$PG_VER" = "16" ]                  && ok "postgres version rolled back: 16"       || warn "postgres version is $PG_VER"
[[ "$PG_CFG" == *pg16* ]]             && ok "SGPostgresConfig: pg16 variant"         || warn "SGPostgresConfig is $PG_CFG"

echo -e "${Y}⚠  NOTE: On real clusters, rolling back a Postgres major version${N}"
echo -e "${Y}   bump requires data migration (pg_dump/pg_restore) — the on-disk${N}"
echo -e "${Y}   format is not backwards-compatible. On kind, the SGCluster CR${N}"
echo -e "${Y}   is a manifest, not a live database, so the rollback is clean.${N}"
echo

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "Postgres version bump demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "Postgres version bump demo finished with failures — see assertions above"
fi
