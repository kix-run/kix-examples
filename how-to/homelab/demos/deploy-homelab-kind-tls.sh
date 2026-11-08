#!/usr/bin/env bash
# deploy-homelab-kind-tls.sh — Deploy the `homelab-kind-tls` variant.
#
# Same homelab services as `deploy-homelab-kind.sh`, but every Ingress gets
# a self-signed TLS cert via cert-manager and a SelfSigned ClusterIssuer.
#
# The story is the padlock: immich / vaultwarden login pages served
# over HTTPS end-to-end with zero external dependencies. Browsers will
# warn on the self-signed chain — that is expected. This tests the
# DI wiring for TLS, not cert-chain trust.
#
# Flow:
#   1. Create kind cluster with default CNI disabled (cilium owns it)
#   2. kix deploy homelab-kind-tls  (installs cilium, ingress-nginx,
#      cert-manager, self-signed ClusterIssuer, immich, vaultwarden,
#      filebrowser, monitoring, …)
#   3. Wait for cilium + cert-manager + ingress-nginx + workloads
#   4. Wait for cert-manager to mint the immich-tls / vaultwarden-tls
#      secrets (ClusterIssuer is self-signed so no ACME round-trip)
#   5. Port-forward ingress-nginx TLS 443 → localhost, plus the
#      per-app services for a direct browser surface
#   6. Open Chrome at https://photos.homelab.lan / https://vaultwarden.homelab.lan
#      (use --add-host flags or /etc/hosts for name resolution; fallback
#      to direct http ports if the Host-header dance is too fiddly)
#
# Usage: ./how-to/homelab/demos/deploy-homelab-kind-tls.sh [--keep] [--recreate] [--connectivity] [--no-preload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab-tls"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
CONNECTIVITY=false
PRELOAD=true

IMMICH_NS="immich"
IMMICH_SVC="immich-server"
IMMICH_PORT=2283
IMMICH_LOCAL=2283

VAULT_NS="vaultwarden"
VAULT_SVC="vaultwarden"
VAULT_PORT=8080
VAULT_LOCAL=8088

# ingress-nginx TLS surface. 443 → local 8443 so we don't need root.
INGRESS_NS="ingress-nginx"
INGRESS_SVC="ingress-nginx"
INGRESS_TLS_LOCAL=8443

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
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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
KIND_CONFIG="$(mktemp -t kix-homelab-tls-kind.XXXXXX.yaml)"
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
    mapfile -t IMAGES < <(kix --no-cache --flake . -q images homelab-kind-tls 2>/dev/null) \
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
log "deploying homelab-kind-tls via kix (flake .)"
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind-tls -y --tui --on-error continue \
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
log "waiting for cert-manager + ingress-nginx + apps (up to 5m each)"
kubectl --context "$KCTX" -n cert-manager rollout status \
    deployment/cert-manager --timeout=5m \
    || warn "cert-manager not ready within timeout"
kubectl --context "$KCTX" -n cert-manager rollout status \
    deployment/cert-manager-webhook --timeout=5m \
    || warn "cert-manager-webhook not ready within timeout"
kubectl --context "$KCTX" -n "$INGRESS_NS" rollout status \
    "deployment/$INGRESS_SVC" --timeout=5m \
    || warn "ingress-nginx not ready within timeout"
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

# ── wait for TLS secrets ────────────────────────────────────────────────
# cert-manager needs a moment to observe the Ingress, create a Certificate
# CR, and mint the secret via the self-signed ClusterIssuer. SelfSigned
# does not round-trip to any external CA so this should be ~seconds.
step_start
log "waiting for cert-manager to mint TLS secrets"
wait_for_secret() {
    local ns="$1" name="$2" tries=60
    while [ $tries -gt 0 ]; do
        if kubectl --context "$KCTX" -n "$ns" get secret "$name" >/dev/null 2>&1; then
            ok "secret $ns/$name minted"
            return 0
        fi
        sleep 2
        tries=$((tries - 1))
    done
    warn "secret $ns/$name not minted within timeout"
    return 1
}
wait_for_secret "$IMMICH_NS" immich-tls || true
wait_for_secret "$VAULT_NS" vaultwarden-tls || true
step_done

# ── narrate the TLS wiring ──────────────────────────────────────────────
log "TLS wiring:"
echo
echo "  ${D}# ClusterIssuers (only the self-signed one should exist):${N}"
kubectl --context "$KCTX" get clusterissuer 2>/dev/null || true
echo
echo "  ${D}# Certificates:${N}"
kubectl --context "$KCTX" get certificate -A 2>/dev/null || true
echo
echo "  ${D}# Ingresses with TLS:${N}"
kubectl --context "$KCTX" get ingress -A 2>/dev/null || true
echo

# ── port-forwards ────────────────────────────────────────────────────────
# ingress-nginx TLS surface. Browser must hit this with a Host header
# (or /etc/hosts mapping) to get the right backend + cert. For users
# without /etc/hosts rights, we also port-forward the app services
# directly as an HTTP fallback.
log "port-forwarding ingress-nginx 443 → https://localhost:$INGRESS_TLS_LOCAL"
kubectl --context "$KCTX" -n "$INGRESS_NS" port-forward \
    "svc/$INGRESS_SVC" "$INGRESS_TLS_LOCAL:443" >/tmp/pf-ingress-tls.log 2>&1 &
PF_PIDS+=($!)

log "port-forwarding immich (direct http) → http://localhost:$IMMICH_LOCAL"
kubectl --context "$KCTX" -n "$IMMICH_NS" port-forward \
    "svc/$IMMICH_SVC" "$IMMICH_LOCAL:$IMMICH_PORT" >/tmp/pf-immich.log 2>&1 &
PF_PIDS+=($!)

log "port-forwarding vaultwarden (direct http) → http://localhost:$VAULT_LOCAL"
kubectl --context "$KCTX" -n "$VAULT_NS" port-forward \
    "svc/$VAULT_SVC" "$VAULT_LOCAL:$VAULT_PORT" >/tmp/pf-vaultwarden.log 2>&1 &
PF_PIDS+=($!)

log "port-forwarding grafana → http://localhost:$GRAFANA_LOCAL"
kubectl --context "$KCTX" -n "$GRAFANA_NS" port-forward \
    "svc/$GRAFANA_SVC" "$GRAFANA_LOCAL:$GRAFANA_PORT" >/tmp/pf-grafana.log 2>&1 &
PF_PIDS+=($!)

sleep 2

ok "homelab-kind-tls deployed — port-forwards running"
echo
ok "HTTPS surface (self-signed — browser will warn):"
echo "  immich      : curl -k --resolve photos.homelab.lan:$INGRESS_TLS_LOCAL:127.0.0.1 https://photos.homelab.lan:$INGRESS_TLS_LOCAL/"
echo "  vaultwarden : curl -k --resolve vaultwarden.homelab.lan:$INGRESS_TLS_LOCAL:127.0.0.1 https://vaultwarden.homelab.lan:$INGRESS_TLS_LOCAL/"
echo
ok "direct http fallback (bypasses TLS, useful for browser without /etc/hosts edits):"
echo "  immich      : http://localhost:$IMMICH_LOCAL"
echo "  vaultwarden : http://localhost:$VAULT_LOCAL/#/login"
echo "  grafana     : http://localhost:$GRAFANA_LOCAL ($GRAFANA_USER / $GRAFANA_PASS)"
echo

# Verify the HTTPS surface actually serves the self-signed cert.
if curl -sk --resolve "photos.homelab.lan:$INGRESS_TLS_LOCAL:127.0.0.1" \
    -o /dev/null -w "%{http_code}\n" "https://photos.homelab.lan:$INGRESS_TLS_LOCAL/" 2>/dev/null \
    | grep -qE '^(200|302|401|404)$'; then
    ok "HTTPS surface responding on photos.homelab.lan"
else
    warn "HTTPS surface not responding yet — cert-manager may still be settling; retry in 30s"
fi

if [ -n "$BROWSER" ]; then
    log "opening Chrome: direct http URLs (browser can't use --resolve, skipping https)"
    "$BROWSER" \
        "http://localhost:$IMMICH_LOCAL" \
        "http://localhost:$VAULT_LOCAL/#/login" \
        "http://localhost:$GRAFANA_LOCAL" >/dev/null 2>&1 &
fi

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
ok "homelab-kind-tls done  ${D}[total: ${TOTAL_ELAPSED}s]${N}"

sleep 5000

if [ "$KEEP" = true ]; then
    trap - EXIT
    warn "--keep set: leaving port-forwards running (pids: ${PF_PIDS[*]})"
    exit 0
fi

wait
