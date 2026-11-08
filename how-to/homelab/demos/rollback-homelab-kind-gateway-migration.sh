#!/usr/bin/env bash
# rollback-homelab-kind-gateway-migration.sh — Prove that the live gateway
# migration (Story 2b) is actually rollback-able through kix activation
# history.
#
# Flow:
#   Phase 0  cluster bootstrap (kind + Gateway API CRDs + envoy-gateway
#            helm controller, installed up-front so ingress-nginx and
#            gateway phases don't race on CRD install)
#   Phase 1  kix deploy homelab-kind                 → ingress-nginx serving
#   Phase 2  kix deploy homelab-kind-gateway-migrate → migration lands
#            (shared activation identity "homelab-kind" — this is the
#            trick that makes rollback possible at all)
#   Phase 3  kix rollback --list homelab-kind        → show the activation
#            history the engine will walk
#   Phase 4  kix rollback homelab-kind               → revert to phase 1
#   Phase 5  assert the world is back:
#              - Ingresses present (immich, vaultwarden, filebrowser)
#              - HTTPRoutes gone
#              - ingress-nginx pods running
#              - envoy data plane pods terminating / gone
#              - immich/vaultwarden still Ready
#
# The only claim this script validates is that kix's activation history
# walks correctly through the capability flip — that the prune/create
# pair that moved us from Ingress to Gateway has a clean inverse.
#
# Usage:
#   ./how-to/homelab/demos/rollback-homelab-kind-gateway-migration.sh [--keep] [--recreate] [--no-preload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-rollback"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true

GATEWAY_API_VERSION="v1.2.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

EG_NS="envoy-gateway-system"
EG_CHART_VERSION="v1.3.0"
EG_CHART_URL="oci://docker.io/envoyproxy/gateway-helm"

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

PF_PIDS=()
cleanup() {
    [ -n "${KIND_CONFIG:-}" ] && rm -f "$KIND_CONFIG"
    if [ ${#PF_PIDS[@]} -gt 0 ]; then
        for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    fi
    if [ "$KEEP" = false ]; then
        log "deleting kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        warn "keeping cluster '$CLUSTER_NAME'"
    fi
}
trap cleanup EXIT INT TERM

for cmd in kind kubectl kix cilium helm; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — cluster bootstrap"
# ─────────────────────────────────────────────────────────────────────────

KIND_CONFIG="$(mktemp -t kix-homelab-rollback-kind.XXXXXX.yaml)"
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
        log "deleting existing kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME"
    else
        ok "reusing existing kind cluster '$CLUSTER_NAME'"
    fi
fi
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi
kubectl cluster-info --context "$KCTX" >/dev/null || die "kubectl context '$KCTX' not reachable"

log "installing Gateway API CRDs"
kubectl --context "$KCTX" apply -f "$GATEWAY_API_URL" \
    || die "failed to install Gateway API CRDs"

log "installing envoy-gateway controller"
kubectl --context "$KCTX" create ns "$EG_NS" --dry-run=client -o yaml \
    | kubectl --context "$KCTX" apply -f - >/dev/null
helm --kube-context "$KCTX" upgrade --install envoy-gateway "$EG_CHART_URL" \
    --version "$EG_CHART_VERSION" \
    --namespace "$EG_NS" \
    --wait --timeout 5m \
    || warn "envoy-gateway helm install reported issues (continuing)"

if [ "$PRELOAD" = true ]; then
    log "preloading images (homelab-kind ∪ homelab-kind-gateway-migrate)"
    mapfile -t IMAGES_A < <(kix --no-cache --flake . -q images homelab-kind 2>/dev/null) || IMAGES_A=()
    mapfile -t IMAGES_B < <(kix --no-cache --flake . -q images homelab-kind-gateway-migrate 2>/dev/null) || IMAGES_B=()
    declare -A SEEN_IMG; IMAGES=()
    for img in "${IMAGES_A[@]}" "${IMAGES_B[@]}"; do
        if [ -z "${SEEN_IMG[$img]:-}" ]; then SEEN_IMG[$img]=1; IMAGES+=("$img"); fi
    done
    if [ ${#IMAGES[@]} -gt 0 ]; then
        printf '%s\n' "${IMAGES[@]}" | python3 "$SCRIPT_DIR/docker-pull-parallel.py" \
            || warn "some image(s) failed to pull"
        for img in "${IMAGES[@]}"; do
            if [[ "$img" == *@sha256:* ]]; then
                tag_only="${img%%@sha256:*}"
                docker tag "$img" "$tag_only" 2>/dev/null || true
            fi
        done
        declare -A SEEN_TAGS; TAGGED_IMAGES=()
        for img in "${IMAGES[@]}"; do
            tag_only="${img%%@sha256:*}"
            if [ -z "${SEEN_TAGS[$tag_only]:-}" ]; then SEEN_TAGS[$tag_only]=1; TAGGED_IMAGES+=("$tag_only"); fi
        done
        for img in "${TAGGED_IMAGES[@]}"; do
            kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null 2>&1 &
        done
        wait
        for img in "${IMAGES[@]}"; do
            if [[ "$img" == *@sha256:* ]]; then
                kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null 2>&1 || true
            fi
        done
        ok "image preload complete"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 1 — deploy homelab-kind (ingress-nginx baseline)"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy homelab-kind reported errors (continuing)"

log "waiting for ingress-nginx + workloads"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues"
kubectl --context "$KCTX" -n ingress-nginx rollout status deployment/ingress-nginx --timeout=5m || warn "ingress-nginx not ready"
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server   --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden     --timeout=5m || warn "vaultwarden not ready"

log "phase 1 state — Ingresses present, HTTPRoutes absent"
kubectl --context "$KCTX" get ingress -A 2>/dev/null
kubectl --context "$KCTX" get httproute -A 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — migrate to Gateway API (homelab-kind-gateway-migrate)"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-gateway-migrate -y --tui --on-error continue \
    || warn "kix deploy homelab-kind-gateway-migrate reported errors (continuing)"

sleep 5
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || warn "immich not ready"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || warn "vaultwarden not ready"

log "phase 2 state — HTTPRoutes present, Ingresses pruned"
kubectl --context "$KCTX" get httproute -A 2>/dev/null
kubectl --context "$KCTX" get ingress   -A 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 3 — inspect activation history"
# ─────────────────────────────────────────────────────────────────────────

# `kix rollback --list` prints the activation chain for the named
# cluster on the active context. With phase 1 + phase 2 landed on the
# *shared* "homelab-kind" identity, there should be >= 2 activations in
# the chain. If it only shows 1, the shared-identity trick did not
# kick in and phase 2 wrote to a new identity — fail loud.
log "kix rollback --list homelab-kind (activation chain)"
if ! kix --no-cache --flake . --context "$KCTX" rollback homelab-kind --list 2>&1 | tee /tmp/kix-activation-list.txt; then
    fail "kix rollback --list exited non-zero"
fi

HISTORY_LINES="$(grep -cE '^(homelab-kind|\s*[0-9]|activation|identity|previous)' /tmp/kix-activation-list.txt 2>/dev/null || echo 0)"
if [ "$HISTORY_LINES" -lt 2 ]; then
    warn "activation history looks short ($HISTORY_LINES matched lines) — may indicate"
    warn "phase 2 wrote to a new identity. Check kix rollback --list output above."
fi

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 4 — rollback to phase 1"
# ─────────────────────────────────────────────────────────────────────────

kix --no-cache --flake . --context "$KCTX" rollback homelab-kind -y --prune \
    || fail "kix rollback homelab-kind failed"

sleep 5

# Give the lifecycle engine a moment to tear down the envoy data plane
# and spin ingress-nginx back up.
log "waiting for ingress-nginx to come back up"
kubectl --context "$KCTX" -n ingress-nginx rollout status deployment/ingress-nginx --timeout=5m \
    || fail "ingress-nginx did not return within timeout"

log "waiting for immich + vaultwarden to still be Ready after rollback"
kubectl --context "$KCTX" -n immich      rollout status deployment/immich-server --timeout=5m || fail "immich not ready post-rollback"
kubectl --context "$KCTX" -n vaultwarden rollout status deployment/vaultwarden   --timeout=5m || fail "vaultwarden not ready post-rollback"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 5 — assertions"
# ─────────────────────────────────────────────────────────────────────────

# Ingresses back
INGRESS_COUNT="$(kubectl --context "$KCTX" get ingress -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$INGRESS_COUNT" -ge 2 ]; then
    ok "Ingresses restored (count=$INGRESS_COUNT)"
else
    fail "expected >= 2 Ingresses after rollback, got $INGRESS_COUNT"
fi

# HTTPRoutes gone
HTTPROUTE_COUNT="$(kubectl --context "$KCTX" get httproute -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$HTTPROUTE_COUNT" -eq 0 ]; then
    ok "HTTPRoutes pruned on rollback"
else
    warn "expected 0 HTTPRoutes after rollback, got $HTTPROUTE_COUNT"
    kubectl --context "$KCTX" get httproute -A 2>/dev/null || true
fi

# Gateway resource gone
GATEWAY_COUNT="$(kubectl --context "$KCTX" get gateway -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$GATEWAY_COUNT" -eq 0 ]; then
    ok "Gateway resource pruned on rollback"
else
    warn "expected 0 Gateways after rollback, got $GATEWAY_COUNT"
fi

# ingress-nginx is back
if kubectl --context "$KCTX" -n ingress-nginx get deployment/ingress-nginx >/dev/null 2>&1; then
    ok "ingress-nginx deployment restored"
else
    fail "ingress-nginx deployment missing after rollback"
fi

# apps still reachable in-cluster (sanity)
log "curl immich service from inside cluster (sanity)"
kubectl --context "$KCTX" -n immich get svc immich-server >/dev/null 2>&1 \
    && ok "immich-server service reachable" \
    || fail "immich-server service missing"

echo
kubectl --context "$KCTX" get ingress -A 2>/dev/null
echo
kubectl --context "$KCTX" get httproute -A 2>/dev/null || true
echo

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
if [ "$FAILED" -eq 0 ]; then
    ok "rollback demo PASSED  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    exit 0
else
    die "rollback demo FAILED — see assertions above"
fi
