#!/usr/bin/env bash
# deploy-homelab-kind-gateway.sh — Deploy the `homelab-kind-gateway` variant.
#
# Same homelab services as `deploy-homelab-kind.sh`, but the L7 layer is
# Gateway API (HTTPRoutes via envoy-gateway) instead of legacy Ingress
# via ingress-nginx.
#
# Flow:
#   1. Create kind cluster with default CNI disabled (so cilium owns it)
#   2. kix deploy homelab-kind-gateway  (installs cilium, the Gateway API
#      CRDs, the Envoy Gateway controller, GatewayClass, Gateway,
#      HTTPRoutes, and every app workload)
#   3. Wait for cilium + workloads
#   4. Port-forward:
#        - the envoy data plane service → localhost:8088  (HTTPRoute surface)
#        - immich / vaultwarden directly → localhost:2283 / 8088 (bypass,
#          browser-friendly)
#        - grafana → localhost:3000
#   5. Narrate the capability flip: `kubectl get httproute -A` versus the
#      zero ingresses that exist on this variant.
#
# Usage: ./how-to/homelab/demos/deploy-homelab-kind-gateway.sh [--keep] [--recreate] [--connectivity] [--no-preload]
#
# NOTE: This is NOT a migration pair with homelab-kind — nothing stateful
# swaps. The story is capability flipping (ingress → gateway) and
# deploy/prune semantics only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-gw"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
CONNECTIVITY=false
PRELOAD=true


# The envoy-gateway instance's namespace, where the controller runs the
# Envoy proxies.
EG_NS="gateway-system"

IMMICH_NS="immich"
IMMICH_SVC="immich-server"
IMMICH_PORT=2283
IMMICH_LOCAL=2283

VAULT_NS="vaultwarden"
VAULT_SVC="vaultwarden"
VAULT_PORT=8080
VAULT_LOCAL=8088

# Envoy data plane port-forward — proves HTTPRoutes are in effect
# (use curl -H "Host: photos.homelab.lan" http://localhost:8000 etc.).
ENVOY_LOCAL=8000

GRAFANA_NS="monitoring-system"
GRAFANA_SVC="grafana"
GRAFANA_PORT=80
GRAFANA_LOCAL=3000
GRAFANA_USER="admin"
GRAFANA_PASS="dev-password"  # set in how-to/homelab/base.nix

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        --recreate) RECREATE=true ;;
        --connectivity) CONNECTIVITY=true ;;
        --no-preload) PRELOAD=false ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; D='\033[0;90m'; N='\033[0m'
log() { echo -e "${B}==>${N} $*"; }
ok()  { echo -e "${G}✓${N} $*"; }
warn(){ echo -e "${Y}!${N} $*"; }
die() { echo -e "${R}✗${N} $*" >&2; exit 1; }

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
for cmd in kind kubectl kix cilium; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

BROWSER=""
for c in google-chrome google-chrome-stable chromium chrome brave xdg-open; do
    if command -v "$c" >/dev/null; then BROWSER="$c"; break; fi
done
[ -n "$BROWSER" ] || warn "no chrome found; will print URLs instead of opening"

# ── kind cluster ─────────────────────────────────────────────────────────
KIND_CONFIG="$(mktemp -t kix-homelab-gw-kind.XXXXXX.yaml)"
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
kubectl cluster-info --context "$KCTX" >/dev/null \
    || die "kubectl context '$KCTX' not reachable"
step_done

# ── preload images ──────────────────────────────────────────────────────
if [ "$PRELOAD" = true ]; then
    step_start
    log "extracting image list via kix images"
    mapfile -t IMAGES < <(kix --no-cache --flake . -q images homelab-kind-gateway 2>/dev/null) \
        || IMAGES=()
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
        warn "kix images failed — skipping image preload"
    fi
fi

# ── deploy with kix ──────────────────────────────────────────────────────
step_start
log "deploying homelab-kind-gateway via kix (flake .)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-gateway -y --tui --on-error continue \
    || warn "kix deploy reported errors (continuing)"
step_done

# ── cilium readiness ─────────────────────────────────────────────────────
step_start
log "waiting for cilium to be Ready"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
    cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues (continuing)"
step_done

if [ "$CONNECTIVITY" = true ]; then
    step_start
    log "running cilium connectivity test"
    KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
        cilium --context "$KCTX" connectivity test \
        || warn "cilium connectivity test reported failures (continuing)"
    step_done
fi

# ── wait for workloads ───────────────────────────────────────────────────
step_start
log "waiting for immich + vaultwarden + grafana to be Ready (up to 5m each)"
kubectl --context "$KCTX" -n "$IMMICH_NS" rollout status \
    "deployment/$IMMICH_SVC" --timeout=5m \
    || warn "immich-server not ready within timeout"
kubectl --context "$KCTX" -n "$VAULT_NS" rollout status \
    "deployment/$VAULT_SVC" --timeout=5m \
    || warn "vaultwarden not ready within timeout"
kubectl --context "$KCTX" -n "$GRAFANA_NS" rollout status \
    "deployment/$GRAFANA_SVC" --timeout=5m \
    || warn "grafana not ready within timeout"
step_done

# ── narrate the capability flip ─────────────────────────────────────────
log "capability flip: HTTPRoutes instead of Ingresses"
echo
echo "  ${D}# HTTPRoutes (this variant):${N}"
kubectl --context "$KCTX" get httproute -A 2>/dev/null || warn "no HTTPRoutes found"
echo
echo "  ${D}# Ingresses (should be empty):${N}"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo
echo "  ${D}# Gateway:${N}"
kubectl --context "$KCTX" get gateway -A 2>/dev/null || true
echo

# ── port-forwards ────────────────────────────────────────────────────────
# The envoy data plane service is named by envoy-gateway as
# `envoy-<namespace>-<gateway-name>-<hash>` in the controller's namespace.
# Look it up by label instead of name so the hash drift is harmless.
log "looking up envoy data plane service"
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

IMMICH_URL="http://localhost:$IMMICH_LOCAL"
VAULT_URL="http://localhost:$VAULT_LOCAL/#/login"
GRAFANA_URL="http://localhost:$GRAFANA_LOCAL"

if [ -n "$BROWSER" ]; then
    log "opening Chrome: $IMMICH_URL  &  $VAULT_URL  &  $GRAFANA_URL"
    "$BROWSER" "$IMMICH_URL" "$VAULT_URL" "$GRAFANA_URL" >/dev/null 2>&1 &
else
    echo "  immich     : $IMMICH_URL"
    echo "  vaultwarden: $VAULT_URL"
    echo "  grafana    : $GRAFANA_URL  ($GRAFANA_USER / $GRAFANA_PASS)"
fi

if [ -n "$ENVOY_SVC" ]; then
    echo
    ok "HTTPRoute surface (envoy data plane) at http://localhost:$ENVOY_LOCAL — use Host headers:"
    echo "  curl -H 'Host: photos.homelab.lan'      http://localhost:$ENVOY_LOCAL/"
    echo "  curl -H 'Host: vaultwarden.homelab.lan' http://localhost:$ENVOY_LOCAL/"
fi

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
ok "homelab-kind-gateway deployed — port-forwards running (Ctrl-C to tear down)  ${D}[total: ${TOTAL_ELAPSED}s]${N}"

sleep 5000

if [ "$KEEP" = true ]; then
    trap - EXIT
    warn "--keep set: leaving port-forwards running in background (pids: ${PF_PIDS[*]})"
    exit 0
fi

wait
