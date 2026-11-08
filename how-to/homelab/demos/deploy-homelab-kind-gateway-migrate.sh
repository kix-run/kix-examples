#!/usr/bin/env bash
# deploy-homelab-kind-gateway-migrate.sh — Live migrate homelab from legacy
# Ingress (ingress-nginx) to Gateway API (envoy-gateway) on a running
# kind cluster. Variant of Story 2: instead of a zero-install gateway
# deploy, this tests the *overlap window* — ingress-nginx already
# serving immich/vaultwarden, then kix re-deploys the same services
# onto envoy-gateway.
#
# It is *not* a migration pair — nothing stateful swaps. This tests
# deploy/prune semantics and capability switching only.
#
# Activation identity — the phase 2 flake output
# `homelab-kind-gateway-migrate` *shares* its internal cluster name
# (`homelab-kind`) with the phase 1 baseline via
# `how-to/homelab/cluster-kind-gateway-migrate.nix`. Because the activation name
# matches, kix treats phase 2 as an upgrade of the phase 1 activation
# instead of a fresh install. The lifecycle engine then owns pruning
# the old ingress-nginx package and creating the new gateway
# resources as a single activation transition — and `kix rollback
# homelab-kind` reverts it.
#
# Flow:
#   Phase 0 — cluster bootstrap
#     1. Create kind cluster with default CNI disabled
#     2. Install Gateway API CRDs up-front (harmless while idle —
#        nothing references them yet in phase 1)
#     3. Install envoy-gateway controller via helm up-front (same —
#        idles until a GatewayClass with its controller name exists)
#
#   Phase 1 — ingress world
#     4. kix deploy homelab-kind
#     5. Wait for cilium, ingress-nginx, immich, vaultwarden, grafana
#     6. Narrate: `kubectl get ingress -A` — this is the baseline
#
#   Phase 2 — live migration
#     7. kix diff homelab-kind-gateway-migrate  (print the planned change)
#     8. kix deploy homelab-kind-gateway-migrate on the same context — lifecycle
#        engine prunes ingress-nginx package + Ingresses, creates
#        GatewayClass + Gateway + HTTPRoutes. Overlap window owned
#        by kix.
#     9. kix gc  (best effort — clean any stale kix-managed resources)
#    10. Narrate: Ingresses gone, HTTPRoutes present, ingress-nginx
#        pods terminating, envoy data plane pods starting
#    11. Port-forward envoy data plane + services; print curl probes
#
# Usage: ./how-to/homelab/demos/deploy-homelab-kind-gateway-migrate.sh [--keep] [--recreate] [--no-preload] [--pause SEC]
#   --pause SEC  : seconds to hold at the phase-1 baseline before
#                  starting the migration. Default 10. Use a longer
#                  value when demoing to a human watching the screen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-migrate"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
PRELOAD=true
PAUSE_SECONDS=10

GATEWAY_API_VERSION="v1.2.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

EG_NS="envoy-gateway-system"
EG_CHART_VERSION="v1.3.0"
EG_CHART_URL="oci://docker.io/envoyproxy/gateway-helm"

IMMICH_NS="immich"
IMMICH_SVC="immich-server"
IMMICH_PORT=2283
IMMICH_LOCAL=2283

VAULT_NS="vaultwarden"
VAULT_SVC="vaultwarden"
VAULT_PORT=8080
VAULT_LOCAL=8088

ENVOY_LOCAL=8000

GRAFANA_NS="monitoring-system"
GRAFANA_SVC="grafana"
GRAFANA_PORT=80
GRAFANA_LOCAL=3000

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --no-preload) PRELOAD=false ;;
        --pause) shift; PAUSE_SECONDS="$1" ;;
        --pause=*) PAUSE_SECONDS="${arg#--pause=}" ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; D='\033[0;90m'; M='\033[0;35m'; N='\033[0m'
log()   { echo -e "${B}==>${N} $*"; }
phase() { echo -e "\n${M}━━━ $* ━━━${N}\n"; }
ok()    { echo -e "${G}✓${N} $*"; }
warn()  { echo -e "${Y}!${N} $*"; }
die()   { echo -e "${R}✗${N} $*" >&2; exit 1; }

SCRIPT_START=$SECONDS
step_start() { STEP_START=$SECONDS; }
step_done()  { local elapsed=$(( SECONDS - STEP_START )); echo -e "  ${D}(${elapsed}s)${N}"; }

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
        warn "keeping cluster '$CLUSTER_NAME' (delete with: kind delete cluster --name $CLUSTER_NAME)"
    fi
}
trap cleanup EXIT INT TERM

# ── prerequisites ────────────────────────────────────────────────────────
for cmd in kind kubectl kix cilium helm; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

BROWSER=""
for c in google-chrome google-chrome-stable chromium chrome brave xdg-open; do
    if command -v "$c" >/dev/null; then BROWSER="$c"; break; fi
done

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 0 — cluster bootstrap"
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

step_start
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    if [ "$RECREATE" = true ]; then
        log "deleting existing kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME"
    else
        ok "reusing existing kind cluster '$CLUSTER_NAME'"
    fi
fi
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "creating kind cluster '$CLUSTER_NAME' (default CNI disabled)"
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi
kubectl cluster-info --context "$KCTX" >/dev/null || die "kubectl context '$KCTX' not reachable"
step_done

# Install Gateway API CRDs + envoy-gateway controller up front. Idle in
# phase 1 (nothing references them yet), active once phase 2 creates
# GatewayClass/Gateway/HTTPRoutes. Doing this up front avoids a
# mid-migration CRD install racing with the lifecycle engine.
step_start
log "installing Gateway API CRDs ($GATEWAY_API_VERSION, standard channel)"
kubectl --context "$KCTX" apply -f "$GATEWAY_API_URL" \
    || die "failed to install Gateway API CRDs"
step_done

step_start
log "installing envoy-gateway controller ($EG_CHART_VERSION) via helm (idle until phase 2)"
kubectl --context "$KCTX" create ns "$EG_NS" --dry-run=client -o yaml \
    | kubectl --context "$KCTX" apply -f - >/dev/null
helm --kube-context "$KCTX" upgrade --install envoy-gateway "$EG_CHART_URL" \
    --version "$EG_CHART_VERSION" \
    --namespace "$EG_NS" \
    --wait --timeout 5m \
    || warn "envoy-gateway helm install reported issues (continuing)"
step_done

# ── preload images (both activations' union) ─────────────────────────────
if [ "$PRELOAD" = true ]; then
    step_start
    log "extracting image list via kix images (homelab-kind ∪ homelab-kind-gateway-migrate)"
    mapfile -t IMAGES_A < <(kix --no-cache --flake . -q images homelab-kind 2>/dev/null) || IMAGES_A=()
    mapfile -t IMAGES_B < <(kix --no-cache --flake . -q images homelab-kind-gateway-migrate 2>/dev/null) || IMAGES_B=()
    declare -A SEEN_IMG
    IMAGES=()
    for img in "${IMAGES_A[@]}" "${IMAGES_B[@]}"; do
        if [ -z "${SEEN_IMG[$img]:-}" ]; then
            SEEN_IMG[$img]=1
            IMAGES+=("$img")
        fi
    done
    step_done
    if [ ${#IMAGES[@]} -gt 0 ]; then
        step_start
        log "preloading ${#IMAGES[@]} images (parallel docker pull → kind load)"
        printf '%s\n' "${IMAGES[@]}" | python3 "$SCRIPT_DIR/docker-pull-parallel.py" \
            || warn "some image(s) failed to pull"

        for img in "${IMAGES[@]}"; do
            if [[ "$img" == *@sha256:* ]]; then
                tag_only="${img%%@sha256:*}"
                docker tag "$img" "$tag_only" 2>/dev/null || true
            fi
        done

        declare -A SEEN_TAGS
        TAGGED_IMAGES=()
        for img in "${IMAGES[@]}"; do
            tag_only="${img%%@sha256:*}"
            if [ -z "${SEEN_TAGS[$tag_only]:-}" ]; then
                SEEN_TAGS[$tag_only]=1
                TAGGED_IMAGES+=("$tag_only")
            fi
        done

        step_done
        step_start
        log "loading ${#TAGGED_IMAGES[@]} images into kind cluster (parallel)"
        LOAD_PIDS=()
        for img in "${TAGGED_IMAGES[@]}"; do
            kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null 2>&1 &
            LOAD_PIDS+=($!)
        done
        LOAD_DONE=0
        LOAD_TOTAL=${#TAGGED_IMAGES[@]}
        for pid in "${LOAD_PIDS[@]}"; do
            wait "$pid" || true
            LOAD_DONE=$((LOAD_DONE + 1))
            printf "\r  loaded %d/%d images" "$LOAD_DONE" "$LOAD_TOTAL"
        done
        echo

        for img in "${IMAGES[@]}"; do
            if [[ "$img" == *@sha256:* ]]; then
                kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null 2>&1 \
                    || warn "failed to add digest ref for $img"
            fi
        done
        ok "image preload complete"
        step_done
    else
        warn "kix images failed — skipping preload"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 1 — ingress-nginx world (homelab-kind)"
# ─────────────────────────────────────────────────────────────────────────

step_start
log "deploying homelab-kind via kix (ingress-nginx L7)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy homelab-kind reported errors (continuing)"
step_done

step_start
log "waiting for cilium + ingress-nginx + apps"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues (continuing)"
kubectl --context "$KCTX" -n ingress-nginx rollout status deployment/ingress-nginx --timeout=5m \
    || warn "ingress-nginx not ready within timeout"
kubectl --context "$KCTX" -n "$IMMICH_NS" rollout status "deployment/$IMMICH_SVC" --timeout=5m \
    || warn "immich-server not ready within timeout"
kubectl --context "$KCTX" -n "$VAULT_NS" rollout status "deployment/$VAULT_SVC" --timeout=5m \
    || warn "vaultwarden not ready within timeout"
step_done

log "baseline — Ingresses (phase 1):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo
log "baseline — HTTPRoutes (should be empty):"
kubectl --context "$KCTX" get httproute -A 2>/dev/null || true
echo

ok "phase 1 stable — pausing ${PAUSE_SECONDS}s before migrating"
sleep "$PAUSE_SECONDS"

# ─────────────────────────────────────────────────────────────────────────
phase "PHASE 2 — live migration to envoy-gateway (homelab-kind-gateway-migrate)"
# ─────────────────────────────────────────────────────────────────────────

# Show the diff before applying. This is the narration moment — the
# reader sees the capability flip as a plan, not a surprise.
log "kix diff homelab-kind-gateway-migrate (planned migration)"
kix --no-cache --flake . --context "$KCTX" diff homelab-kind-gateway-migrate 2>&1 \
    || warn "kix diff exited non-zero (may be expected — diff is advisory)"
echo

ok "applying migration — kix owns the prune/create overlap window"
sleep 2

# Live deploy over the existing cluster. Desired state swaps
# ingress-nginx → envoy-gateway; kix's lifecycle engine is responsible
# for pruning the ingress-nginx package + per-app Ingress resources
# and creating GatewayClass/Gateway/HTTPRoutes.
step_start
log "deploying homelab-kind-gateway-migrate via kix (same context, live migration)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-gateway-migrate -y --tui --on-error continue \
    || warn "kix deploy homelab-kind-gateway-migrate reported errors (continuing)"
step_done

# Best-effort gc in case the lifecycle engine leaves stale kix-managed
# resources behind. If this no-ops the migration was clean.
step_start
log "kix gc (sweep any stale kix-managed resources)"
kix --no-cache --flake . --context "$KCTX" gc homelab-kind-gateway-migrate -y 2>&1 \
    || warn "kix gc exited non-zero (continuing — may be unimplemented or a no-op)"
step_done

step_start
log "waiting for envoy data plane + apps"
# Envoy Gateway creates the data plane Deployment lazily once the
# Gateway resource is reconciled. Give it a moment.
sleep 5
kubectl --context "$KCTX" -n "$IMMICH_NS" rollout status "deployment/$IMMICH_SVC" --timeout=5m \
    || warn "immich-server not ready within timeout"
kubectl --context "$KCTX" -n "$VAULT_NS" rollout status "deployment/$VAULT_SVC" --timeout=5m \
    || warn "vaultwarden not ready within timeout"
step_done

log "post-migration — Ingresses (should be empty or pruning):"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo
log "post-migration — HTTPRoutes (phase 2 target):"
kubectl --context "$KCTX" get httproute -A 2>/dev/null || true
echo
log "post-migration — Gateway:"
kubectl --context "$KCTX" get gateway -A 2>/dev/null || true
echo
log "post-migration — ingress-nginx pods (should be terminating or gone):"
kubectl --context "$KCTX" -n ingress-nginx get pods 2>/dev/null \
    || ok "ingress-nginx namespace already cleaned"
echo

# ── port-forwards ───────────────────────────────────────────────────────
ENVOY_SVC="$(kubectl --context "$KCTX" -n "$EG_NS" get svc \
    -l gateway.envoyproxy.io/owning-gateway-namespace=gateway-system \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$ENVOY_SVC" ]; then
    log "port-forwarding envoy data plane ($ENVOY_SVC) → http://localhost:$ENVOY_LOCAL"
    kubectl --context "$KCTX" -n "$EG_NS" port-forward \
        "svc/$ENVOY_SVC" "$ENVOY_LOCAL:80" >/tmp/pf-envoy.log 2>&1 &
    PF_PIDS+=($!)
else
    warn "could not locate envoy data plane service — HTTPRoute-surface port-forward skipped"
fi

log "port-forwarding immich (direct) → http://localhost:$IMMICH_LOCAL"
kubectl --context "$KCTX" -n "$IMMICH_NS" port-forward \
    "svc/$IMMICH_SVC" "$IMMICH_LOCAL:$IMMICH_PORT" >/tmp/pf-immich.log 2>&1 &
PF_PIDS+=($!)

log "port-forwarding vaultwarden (direct) → http://localhost:$VAULT_LOCAL"
kubectl --context "$KCTX" -n "$VAULT_NS" port-forward \
    "svc/$VAULT_SVC" "$VAULT_LOCAL:$VAULT_PORT" >/tmp/pf-vaultwarden.log 2>&1 &
PF_PIDS+=($!)

log "port-forwarding grafana → http://localhost:$GRAFANA_LOCAL"
kubectl --context "$KCTX" -n "$GRAFANA_NS" port-forward \
    "svc/$GRAFANA_SVC" "$GRAFANA_LOCAL:$GRAFANA_PORT" >/tmp/pf-grafana.log 2>&1 &
PF_PIDS+=($!)

sleep 2

if [ -n "$ENVOY_SVC" ]; then
    ok "HTTPRoute surface — verify migration landed:"
    echo "  curl -H 'Host: photos.homelab.lan'      http://localhost:$ENVOY_LOCAL/"
    echo "  curl -H 'Host: vaultwarden.homelab.lan' http://localhost:$ENVOY_LOCAL/"
fi

echo
ok "direct http fallback (bypasses gateway):"
echo "  immich      : http://localhost:$IMMICH_LOCAL"
echo "  vaultwarden : http://localhost:$VAULT_LOCAL/#/login"
echo "  grafana     : http://localhost:$GRAFANA_LOCAL  (admin / dev-password)"

if [ -n "$BROWSER" ]; then
    "$BROWSER" \
        "http://localhost:$IMMICH_LOCAL" \
        "http://localhost:$VAULT_LOCAL/#/login" \
        "http://localhost:$GRAFANA_LOCAL" >/dev/null 2>&1 &
fi

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
ok "live migration complete — cluster is now on Gateway API  ${D}[total: ${TOTAL_ELAPSED}s]${N}"

sleep 5000

if [ "$KEEP" = true ]; then
    trap - EXIT
    warn "--keep set: leaving port-forwards running (pids: ${PF_PIDS[*]})"
    exit 0
fi

wait
