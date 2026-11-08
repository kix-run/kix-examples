#!/usr/bin/env bash
# demo-tls-migration.sh — HTTP → HTTPS migration demo.
#
# Upgrades a running homelab-kind cluster (plain HTTP) to HTTPS by adding
# cert-manager + a self-signed ClusterIssuer. The DI graph wires TLS
# automatically: every package using `kix.expose` gets a TLS Ingress
# once the ClusterIssuer is present, without touching any service config.
#
# Phases:
#   Phase 0  bootstrap   — kind cluster + cilium
#   Phase 1  baseline    — kix deploy homelab-kind (HTTP only)
#   Phase 2  blast radius — deterministic diff (cert-manager resources + TLS Ingresses)
#   Phase 3  upgrade     — kix deploy homelab-kind-tls-migrate (adds TLS)
#   Phase 4  verify      — cert-manager running, TLS secrets minted, HTTPS responding
#   Phase 5  rollback    — kix deploy homelab-kind (TLS removed, back to HTTP)
#
# Usage: ./how-to/homelab/demos/demo-tls-migration.sh [--keep] [--recreate] [--no-preload]

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
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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
    echo "$diff_output" | sed -E "s|${p1}/||g; s|${p2}/||g; s|^|   |" | head -40
    echo
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
    log "preloading images (baseline + TLS variant)"
    # Preload both baseline and TLS images so the upgrade doesn't stall on pulls.
    mapfile -t IMAGES < <(
        { kix --no-cache --flake . -q images homelab-kind 2>/dev/null || true; \
          kix --no-cache --flake . -q images homelab-kind-tls-migrate 2>/dev/null || true; } \
        | sort -u
    )
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
        ok "images preloaded (${#IMAGES[@]} total)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 1 — deploy homelab-kind baseline (HTTP only)"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy homelab-kind reported errors (continuing)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues"
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

log "baseline state — no TLS:"
echo "  cert-manager namespace: $(kubectl --context "$KCTX" get ns cert-manager 2>/dev/null && echo "EXISTS" || echo "does not exist")"
echo "  ClusterIssuers:         $(kubectl --context "$KCTX" get clusterissuer 2>/dev/null | wc -l | tr -d ' ') (expect 0)"
echo "  Ingresses:"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — blast radius: HTTP → HTTPS"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind homelab-kind-tls-migrate \
    "add cert-manager + self-signed ClusterIssuer → TLS on all Ingresses"

echo -e "${M}NOTE: The DI graph wires TLS automatically. Adding a ClusterIssuer${N}"
echo -e "${M}causes every kix.expose-using package to emit TLS annotations on${N}"
echo -e "${M}its Ingress — no per-service config changes needed.${N}"
echo

log "kix diff homelab-kind-tls-migrate"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-tls-migrate 2>&1 | tail -40 || true
echo

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — deploy TLS upgrade"
# ─────────────────────────────────────────────────────────────────────────

log "kix deploy homelab-kind-tls-migrate"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-tls-migrate -y --tui --on-error continue \
    || warn "tls-migrate deploy reported errors (continuing)"

# Wait for cert-manager to come up.
kubectl --context "$KCTX" -n cert-manager rollout status deployment/cert-manager --timeout=5m \
    || warn "cert-manager not ready"
kubectl --context "$KCTX" -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m \
    || warn "cert-manager-webhook not ready"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — verify TLS"
# ─────────────────────────────────────────────────────────────────────────

# Check ClusterIssuer exists.
if kubectl --context "$KCTX" get clusterissuer selfsigned -o name >/dev/null 2>&1; then
    ok "ClusterIssuer 'selfsigned' exists"
else
    fail "ClusterIssuer 'selfsigned' missing"
fi

# Wait for TLS secrets to be minted.
log "waiting for cert-manager to mint TLS secrets (self-signed, should be fast)"
for secret_pair in "immich:immich-tls" "vaultwarden:vaultwarden-tls"; do
    ns="${secret_pair%%:*}"
    secret="${secret_pair##*:}"
    TRIES=30
    while [ $TRIES -gt 0 ]; do
        if kubectl --context "$KCTX" -n "$ns" get secret "$secret" >/dev/null 2>&1; then
            ok "TLS secret $ns/$secret minted"
            break
        fi
        sleep 2
        TRIES=$((TRIES - 1))
    done
    [ $TRIES -gt 0 ] || fail "TLS secret $ns/$secret not minted within timeout"
done

# Show the TLS wiring.
log "post-upgrade state — TLS active:"
echo "  ClusterIssuers:"
kubectl --context "$KCTX" get clusterissuer 2>/dev/null || true
echo "  Certificates:"
kubectl --context "$KCTX" get certificate -A 2>/dev/null || true
echo "  Ingresses (should show TLS hosts):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

# Verify HTTPS is actually responding via ingress-nginx.
INGRESS_TLS_LOCAL=8443
kubectl --context "$KCTX" -n ingress-nginx port-forward svc/ingress-nginx "$INGRESS_TLS_LOCAL:443" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

if curl -sk --resolve "photos.homelab.lan:$INGRESS_TLS_LOCAL:127.0.0.1" \
    -o /dev/null -w "%{http_code}" "https://photos.homelab.lan:$INGRESS_TLS_LOCAL/" 2>/dev/null \
    | grep -qE '^(200|302|401|404)$'; then
    ok "HTTPS responding on photos.homelab.lan:$INGRESS_TLS_LOCAL (self-signed)"
else
    warn "HTTPS not responding yet — cert-manager may still be settling"
fi
kill "$PF_PID" 2>/dev/null || true

log "health check after TLS upgrade"
kix --no-cache --flake . --context "$KCTX" health homelab-kind-tls-migrate || warn "health flagged issues after TLS"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — rollback to HTTP"
# ─────────────────────────────────────────────────────────────────────────

compute_blast_radius homelab-kind-tls-migrate homelab-kind "rollback TLS → HTTP"

log "kix deploy homelab-kind (rolling back — removes cert-manager + TLS)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "rollback deploy reported errors"

sleep 5

log "post-rollback state — TLS removed:"
if kubectl --context "$KCTX" get clusterissuer selfsigned >/dev/null 2>&1; then
    fail "ClusterIssuer 'selfsigned' still exists after rollback"
else
    ok "ClusterIssuer 'selfsigned' pruned"
fi

# cert-manager namespace may linger (K8s doesn't auto-delete empty namespaces)
# but the deployments should be gone.
if kubectl --context "$KCTX" -n cert-manager get deployment cert-manager >/dev/null 2>&1; then
    fail "cert-manager deployment still exists after rollback"
else
    ok "cert-manager deployment pruned"
fi

echo "  Ingresses (should be back to HTTP-only):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

log "health check after rollback"
kix --no-cache --flake . --context "$KCTX" health homelab-kind || warn "health flagged issues after rollback"

echo
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "TLS migration demo complete  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "TLS migration demo finished with failures — see assertions above"
fi
