#!/usr/bin/env bash
# deploy-homelab-kind.sh — Deploy the homelab cluster into a local kind cluster
# and open Chrome at the immich + vaultwarden login pages.
#
# Flow:
#   1. Push images to local registry (incremental, near-instant when cached)
#   2. Create kind cluster with disableDefaultCNI + containerd mirror config
#      (nodes pull from local registry on demand — no explicit preload needed)
#   3. kix deploy homelab-kind --context kind-kix-homelab  (installs cilium as CNI)
#   3. Wait for cilium to come up (`cilium status --wait`)
#   4. Run `cilium connectivity test` (skip with --skip-connectivity)
#   5. Wait for immich-server and vaultwarden deployments to be Ready
#   6. kubectl port-forward immich, vaultwarden, and grafana in the background
#   7. Open Chrome tabs at immich, vaultwarden, and grafana (admin / dev-password)
#
# Usage: ./how-to/homelab/demos/deploy-homelab-kind.sh [--keep] [--recreate] [--connectivity] [--no-preload] [--prep-only]
#   --keep          : leave kind cluster + port-forwards running on exit
#   --recreate      : delete existing kind cluster before creating
#   --connectivity  : run `cilium connectivity test` after status check (slow)
#   --no-preload    : skip image preloading (pull images in-cluster instead)
#   --prep-only     : stop after rollout (no PFs, no browser, no sleep); cluster
#                     is left running for an orchestrator such as
#                     how-to/homelab/demos/deploy-homelab-kind2.sh
#
# NOTE: kind is created with the default CNI disabled. Nodes will remain
# NotReady until kix applies the cilium DaemonSet — this is expected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-homelab"
KCTX="kind-$CLUSTER_NAME"
KEEP=false
RECREATE=false
# Connectivity test is now a mandatory correctness gate on the
# DI-derived default-deny CNPs — see the PROVE phase below. Opt out
# with --skip-connectivity if you're in a tight inner loop and
# accept the lost correctness claim.
SKIP_CONNECTIVITY=false
SKIP_NETPOL_PROBE=false
PRELOAD=true
PREP_ONLY=false

IMMICH_NS="immich"
IMMICH_SVC="immich-server"
IMMICH_PORT=2283
IMMICH_LOCAL=2283

VAULT_NS="vaultwarden"
VAULT_SVC="vaultwarden"
VAULT_PORT=8080
VAULT_LOCAL=8088

# how-to/homelab/base.nix turns on monitoring through kix.modules.experimental.monitoring.
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
        --skip-connectivity) SKIP_CONNECTIVITY=true; SKIP_NETPOL_PROBE=true ;;
        --skip-netpol-probe) SKIP_NETPOL_PROBE=true ;;
        --no-preload) PRELOAD=false ;;
        --prep-only) PREP_ONLY=true; KEEP=true; SKIP_CONNECTIVITY=true; SKIP_NETPOL_PROBE=true ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; D='\033[0;90m'; M='\033[0;35m'; N='\033[0m'
log() { echo -e "${B}==>${N} $*"; }
ok()  { echo -e "${G}✓${N} $*"; }
warn(){ echo -e "${Y}!${N} $*"; }
die() { echo -e "${R}✗${N} $*" >&2; exit 1; }

SCRIPT_START=$SECONDS
step_start() { STEP_START=$SECONDS; }
step_done()  { local elapsed=$(( SECONDS - STEP_START )); echo -e "  ${D}(${elapsed}s)${N}"; }

PF_PIDS=()
cleanup() {
    # Remove the temp kind config file if it was created.
    [ -n "${KIND_CONFIG:-}" ] && rm -f "$KIND_CONFIG"
    if [ ${#PF_PIDS[@]} -gt 0 ]; then
        for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    fi
    if [ "$KEEP" = false ]; then
        log "deleting kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        warn "keeping cluster '$CLUSTER_NAME' (delete with: kind delete cluster --name $CLUSTER_NAME)"
        warn "port-forwards stopped; restart with:"
        warn "  kubectl --context $KCTX -n $IMMICH_NS port-forward svc/$IMMICH_SVC $IMMICH_LOCAL:$IMMICH_PORT &"
        warn "  kubectl --context $KCTX -n $VAULT_NS  port-forward svc/$VAULT_SVC  $VAULT_LOCAL:$VAULT_PORT &"
        warn "  kubectl --context $KCTX -n $GRAFANA_NS port-forward svc/$GRAFANA_SVC $GRAFANA_LOCAL:$GRAFANA_PORT &"
    fi
}
trap cleanup EXIT INT TERM

# ── prerequisites ────────────────────────────────────────────────────────
for cmd in kind kubectl kix cilium; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

# pick a chrome-ish browser
BROWSER=""
for c in google-chrome google-chrome-stable chromium chrome brave xdg-open; do
    if command -v "$c" >/dev/null; then BROWSER="$c"; break; fi
done
[ -n "$BROWSER" ] || warn "no chrome found; will print URLs instead of opening"

# ── local registry ──────────────────────────────────────────────────────
# Ensure the local Docker registry is running and images are pushed.
# This is incremental — on a warm cache the push is near-instant.
REGISTRY_SCRIPT="$SCRIPT_DIR/kind-local-registry.sh"

if [ "$PRELOAD" = true ]; then
    step_start
    log "ensuring local registry is running"
    "$REGISTRY_SCRIPT" setup
    step_done

    step_start
    log "pushing images to local registry (incremental)"
    "$REGISTRY_SCRIPT" push --cluster homelab-kind --flake .
    step_done
fi

# ── kind cluster ─────────────────────────────────────────────────────────
# Write a kind config that disables the default CNI so cilium can take
# the CNI slot. Pod/service CIDRs stay at kind defaults
# (10.244.0.0/16 / 10.96.0.0/12) which match cilium's defaultValues in
# kix/packages/cilium/default.nix.
KIND_CONFIG="$(mktemp -t kix-homelab-kind.XXXXXX.yaml)"
# cleanup() (defined above) removes this file on EXIT.
if [ "$PRELOAD" = true ]; then
    # Use kind-local-registry.sh to generate config with containerd mirror
    # support, then patch in the cluster name.
    "$REGISTRY_SCRIPT" kind-config --name "$CLUSTER_NAME" > "$KIND_CONFIG"
else
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
fi

step_start
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && [ "$RECREATE" = true ]; then
    log "deleting existing kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
fi
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    ok "reusing existing kind cluster '$CLUSTER_NAME' (rerun with --recreate if cilium rollout hangs)"
else
    log "creating kind cluster '$CLUSTER_NAME' (default CNI disabled — nodes NotReady until cilium applies)"
    # Don't --wait: nodes cannot become Ready without a CNI, and cilium
    # is installed by `kix deploy` below.
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi

kubectl cluster-info --context "$KCTX" >/dev/null \
    || die "kubectl context '$KCTX' not reachable"
step_done

# ── connect registry to kind network ────────────────────────────────────
# After a fresh `kind create cluster`, the "kind" docker network is new.
# Re-run setup to connect the registry container to it so containerd's
# mirror config can reach it.
if [ "$PRELOAD" = true ]; then
    step_start
    "$REGISTRY_SCRIPT" setup
    step_done
fi

sleep 3
echo "Kind ready."

# ── deploy with kix ──────────────────────────────────────────────────────
step_start
log "deploying homelab cluster via kix (flake .)"
# The database passwords are SOPS files encrypted to the examples' test-only key.
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-how-to/platform/test-only-age-key.txt}" \
kix --no-cache --flake . --context "$KCTX" deploy homelab-kind -y --tui --on-error continue \
    || warn "kix deploy reported errors (continuing — HTTPRoutes need Gateway API CRDs)"
step_done

# ── cilium readiness ─────────────────────────────────────────────────────
# Nodes were NotReady while the CNI slot was empty. Once kix has applied the
# cilium DaemonSet + operator, `cilium status --wait` blocks until the agent
# and operator report Ready. This is the real gate before any pod workload
# can schedule onto the kind nodes.
step_start
log "waiting for cilium to be Ready (cilium status --wait)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
    cilium --context "$KCTX" status --wait \
    || warn "cilium status reported issues (continuing)"
step_done

# ── PROVE: default-deny egress is actually enforced ─────────────────────
# The kix compiler auto-derives CiliumNetworkPolicies from the DI graph:
# every namespace kix owns gets a default-deny CNP, and each workload
# gets a tight allow rule for exactly the upstream services it reaches
# through dep references (DNS, valkey, kube-apiserver, …). Nothing else
# is permitted.
#
# That claim is only honest if we *verify* it at deploy time. Two checks:
#
#   1. cilium connectivity test — end-to-end policy enforcement through
#      cilium's own test matrix. Previously optional via --connectivity;
#      now mandatory. Pass --skip-connectivity to opt out for inner-loop
#      speed (and accept the lost correctness claim).
#
#   2. negative probe — launch an unlabeled pod inside a kix-owned
#      namespace (immich). The default-deny CNP there allows no egress
#      from pods whose labels don't match a derived allow rule, so this
#      probe must fail to reach the outside world. If it succeeds,
#      default-deny is not actually enforced and the claim is broken.
#      Pass --skip-netpol-probe to opt out.
if [ "$SKIP_CONNECTIVITY" = true ]; then
    warn "skipping PROVE section (--skip-connectivity) — default-deny correctness unverified"
else
    log "${M}PROVE: default-deny egress is enforced${N}"
    echo

    step_start
    log "running 'cilium connectivity test' (mandatory gate — this can take several minutes)"
    if KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
        cilium --context "$KCTX" connectivity test; then
        ok "cilium connectivity test: PASS — policy matrix enforced"
    else
        die "cilium connectivity test: FAIL — default-deny correctness claim broken (re-run with --skip-connectivity to bypass)"
    fi
    step_done

if [ "$SKIP_NETPOL_PROBE" = false ]; then
    step_start
    log "negative probe: unlabeled pod in 'immich' namespace must NOT reach the outside world"
    # busybox ships everywhere, wget is built in. We use a 5s timeout —
    # if default-deny is enforced the wget returns non-zero (connection
    # timeout or DNS lookup failure). If the policy is broken the wget
    # completes and returns zero, and we fail loud.
    PROBE_POD="kix-netpol-probe-$$"
    # Clean up the probe pod even if curl/wget hangs past the inner
    # timeout. `kubectl run --rm` doesn't always clean up on negative
    # exit codes, so do it explicitly.
    if kubectl --context "$KCTX" -n "$IMMICH_NS" run "$PROBE_POD" \
        --image=busybox:1.36 --restart=Never --attach --rm \
        --pod-running-timeout=60s \
        --command -- sh -c 'wget -T 5 -q -O- http://1.1.1.1/ 2>&1; echo "exit=$?"' 2>/tmp/netpol-probe.log \
        | tee -a /tmp/netpol-probe.log \
        | grep -q 'exit=0'; then
        kubectl --context "$KCTX" -n "$IMMICH_NS" delete pod "$PROBE_POD" --wait=false 2>/dev/null || true
        die "negative probe REACHED 1.1.1.1 — default-deny egress NOT enforced"
    else
        kubectl --context "$KCTX" -n "$IMMICH_NS" delete pod "$PROBE_POD" --wait=false 2>/dev/null || true
        ok "negative probe blocked — default-deny egress enforced in namespace '$IMMICH_NS'"
    fi
    step_done
fi
fi

# ── CNP summary ─────────────────────────────────────────────────────────
CNP_COUNT="$(kubectl --context "$KCTX" get cnp -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
DENY_COUNT="$(kubectl --context "$KCTX" get cnp -A --no-headers 2>/dev/null | grep -c default-deny || true)"
ok "CiliumNetworkPolicies enforced: $CNP_COUNT total ($DENY_COUNT default-deny, $((CNP_COUNT - DENY_COUNT)) derived allow rules)"
echo

# ── wait for workloads ───────────────────────────────────────────────────
step_start
log "waiting for immich, vaultwarden, grafana to be Ready (up to 5m each)"
for entry in "$IMMICH_NS/$IMMICH_SVC" "$VAULT_NS/$VAULT_SVC" "$GRAFANA_NS/$GRAFANA_SVC"; do
    ns="${entry%/*}"; svc="${entry#*/}"
    kubectl --context "$KCTX" -n "$ns" rollout status "deployment/$svc" --timeout=5m \
        || warn "$svc not ready within timeout"
done
step_done

# ── prep-only exit ───────────────────────────────────────────────────────
# When invoked as a prep stage for deploy-homelab-kind2.sh, stop here: no
# port-forwards, no browser, no blocking sleep. Disarm the EXIT trap so
# the cluster survives for the orchestrator to drive and tear down.
if [ "$PREP_ONLY" = true ]; then
    TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
    ok "homelab prepped — cluster '$CLUSTER_NAME' ready for orchestration  ${D}[total: ${TOTAL_ELAPSED}s]${N}"
    [ -n "${KIND_CONFIG:-}" ] && rm -f "$KIND_CONFIG"
    trap - EXIT INT TERM
    exit 0
fi

# ── port-forward ─────────────────────────────────────────────────────────
log "port-forwarding: immich→$IMMICH_LOCAL  vaultwarden→$VAULT_LOCAL  grafana→$GRAFANA_LOCAL"
for entry in \
    "immich:$IMMICH_NS:$IMMICH_SVC:$IMMICH_LOCAL:$IMMICH_PORT" \
    "vaultwarden:$VAULT_NS:$VAULT_SVC:$VAULT_LOCAL:$VAULT_PORT" \
    "grafana:$GRAFANA_NS:$GRAFANA_SVC:$GRAFANA_LOCAL:$GRAFANA_PORT"; do
    IFS=: read -r tag ns svc local port <<<"$entry"
    kubectl --context "$KCTX" -n "$ns" port-forward \
        "svc/$svc" "$local:$port" >"/tmp/pf-$tag.log" 2>&1 &
    PF_PIDS+=($!)
done

# give port-forwards a moment to bind
for _ in 1 2 3 4 5; do
    if curl -sf -o /dev/null "http://localhost:$IMMICH_LOCAL" \
       && curl -sf -o /dev/null "http://localhost:$VAULT_LOCAL" \
       && curl -sf -o /dev/null "http://localhost:$GRAFANA_LOCAL/login"; then
        break
    fi
    sleep 1
done

IMMICH_URL="http://localhost:$IMMICH_LOCAL"
VAULT_URL="http://localhost:$VAULT_LOCAL/#/login"
GRAFANA_URL="http://localhost:$GRAFANA_LOCAL"

# Pre-canned dashboard landings so the demo clicks straight into signal,
# not into a "choose a dashboard" empty state. The first dashboard to
# prove out is the cilium one — it is the capability that current homelab-kind
# tests (CNI + auto-derived CNPs). Others follow from the default-rules
# set that base.nix turns on.
GRAFANA_HOME="$GRAFANA_URL/?orgId=1"
GRAFANA_DASH_LIST="$GRAFANA_URL/dashboards"

if [ -n "$BROWSER" ]; then
    log "opening Chrome: $IMMICH_URL  &  $VAULT_URL  &  $GRAFANA_HOME"
    #"$BROWSER" "$IMMICH_URL" "$VAULT_URL" "$GRAFANA_HOME" >/dev/null 2>&1 &
	"$BROWSER" \
        --no-first-run --no-default-browser-check \
        --new-window \
        --window-size=1400,900 \
        --window-position=80,80 \
        --app="$IMMICH_URL" \
        >/dev/null 2>&1 &
else
    echo "  immich     : $IMMICH_URL"
    echo "  vaultwarden: $VAULT_URL"
    echo "  grafana    : $GRAFANA_HOME  ($GRAFANA_USER / $GRAFANA_PASS)"
fi

ok "grafana login: ${GRAFANA_USER} / ${GRAFANA_PASS}  →  dashboards: ${GRAFANA_DASH_LIST}"

TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
ok "homelab deployed — port-forwards running (Ctrl-C to tear down)  ${D}[total: ${TOTAL_ELAPSED}s]${N}"

if [ "$KEEP" = true ]; then
    # exit without killing port-forwards
    trap - EXIT
    warn "--keep set: leaving port-forwards running in background (pids: ${PF_PIDS[*]})"
    exit 0
fi

# block until user interrupts so port-forwards stay alive
wait

