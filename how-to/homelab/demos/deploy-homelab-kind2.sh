#!/usr/bin/env bash
# deploy-homelab-kind2.sh — Self-recording, self-contained homelab kind demo.
#
# Runs deploy-homelab-kind.sh --prep-only inside a tmux split (top pane: k9s
# -A live view; bottom pane: deploy progress), port-forwards the three
# services, pops Google Chrome as a clean app window at immich, holds for
# a configurable viewing window, then tears everything down. Records the
# whole thing via wf-recorder (niri / wlroots screencopy).
#
# Usage: ./how-to/homelab/demos/deploy-homelab-kind2.sh [--hold N] [--no-record] [--keep] [--recreate] [--no-preload]
#   --hold N      : seconds to hold the demo on screen after chrome pops (default: 90)
#   --no-record   : skip wf-recorder capture
#   --keep        : leave kind cluster, port-forwards, chrome, tmux running on exit
#   --recreate    : pass --recreate to deploy-homelab-kind.sh
#   --no-preload  : pass --no-preload to deploy-homelab-kind.sh (skip local registry)
#
# NOTE: deploy-homelab-kind.sh is invoked with --prep-only, which forces
# --skip-connectivity and --skip-netpol-probe. The cilium connectivity
# test and default-deny negative probe that kind.sh now runs as a
# mandatory PROVE phase are therefore NOT part of this recording. If
# the demo should showcase kix's default-deny enforcement end-to-end,
# that opt-out needs to be revisited.
#
# Output: recording lands in how-to/homelab/demos/recordings/homelab-demo-<timestamp>.mp4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

HOLD=90
RECORD=true
KEEP=false
RECREATE=false
NO_PRELOAD=false

CLUSTER_NAME="kix-homelab"
KCTX="kind-$CLUSTER_NAME"

IMMICH_NS="immich";      IMMICH_SVC="immich-server"; IMMICH_PORT=2283; IMMICH_LOCAL=2283
VAULT_NS="vaultwarden";  VAULT_SVC="vaultwarden";    VAULT_PORT=8080;  VAULT_LOCAL=8088
GRAFANA_NS="monitoring-system"; GRAFANA_SVC="grafana"; GRAFANA_PORT=80; GRAFANA_LOCAL=3000

TMUX_SOCK="homelab-demo"
TMUX_SESSION="homelab"
READY_FILE="$(mktemp -t homelab-demo-ready.XXXXXX)"; rm -f "$READY_FILE"
CHROME_PROFILE="$(mktemp -d -t homelab-demo-chrome.XXXXXX)"
REC_PID=""
WATCHER_PID=""
PF_PIDS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --hold) HOLD="$2"; shift 2 ;;
        --no-record) RECORD=false; shift ;;
        --keep) KEEP=true; shift ;;
        --recreate) RECREATE=true; shift ;;
        --no-preload) NO_PRELOAD=true; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${B}==>${N} $*"; }
ok()   { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
die()  { echo -e "${R}✗${N} $*" >&2; exit 1; }

REC_OUT="$SCRIPT_DIR/recordings/homelab-demo-$(date +%Y%m%d-%H%M%S).mp4"

cleanup() {
    trap - EXIT INT TERM
    log "tearing down demo"

    # 1. stop watcher (it may still be waiting for ready flag)
    [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null || true

    # 2. stop port-forwards
    if [ ${#PF_PIDS[@]} -gt 0 ]; then
        for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    fi

    # 3. close chrome demo window (only our isolated profile)
    pkill -f "user-data-dir=$CHROME_PROFILE" 2>/dev/null || true

    # 4. kill tmux session
    tmux -L "$TMUX_SOCK" kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # 5. delete kind cluster unless --keep
    if [ "$KEEP" = false ]; then
        log "deleting kind cluster '$CLUSTER_NAME'"
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        warn "keeping cluster '$CLUSTER_NAME' (delete with: kind delete cluster --name $CLUSTER_NAME)"
    fi

    # 6. stop recorder last so the teardown shows in the capture
    if [ -n "$REC_PID" ]; then
        sleep 1
        kill -INT "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        ok "recording saved: $REC_OUT"
    fi

    rm -rf "$CHROME_PROFILE"
    rm -f "$READY_FILE"
}
trap cleanup EXIT INT TERM

# ── prerequisites ────────────────────────────────────────────────────────
for cmd in tmux k9s kubectl kind kix cilium curl; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done
CHROME=""
for c in google-chrome google-chrome-stable chromium chrome; do
    if command -v "$c" >/dev/null; then CHROME="$c"; break; fi
done
[ -n "$CHROME" ] || die "no google-chrome / chromium found"

if [ "$RECORD" = true ]; then
    command -v wf-recorder >/dev/null || die "wf-recorder not found (needed for --record; pass --no-record to skip)"
fi

# ── start recording ──────────────────────────────────────────────────────
if [ "$RECORD" = true ]; then
    mkdir -p "$(dirname "$REC_OUT")"
    log "starting wf-recorder → $REC_OUT"
    # -y overwrite, -c h264 for portability; default captures focused output.
    wf-recorder -y -c libx264 -f "$REC_OUT" >/tmp/wf-recorder.log 2>&1 &
    REC_PID=$!
    sleep 1
    kill -0 "$REC_PID" 2>/dev/null \
        || die "wf-recorder failed to start (see /tmp/wf-recorder.log)"
fi

# ── tmux layout ──────────────────────────────────────────────────────────
log "spawning tmux session '$TMUX_SESSION' (top: k9s, bottom: deploy)"
tmux -L "$TMUX_SOCK" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
tmux -L "$TMUX_SOCK" new-session -d -s "$TMUX_SESSION" -x 200 -y 55
tmux -L "$TMUX_SOCK" set -g status off
tmux -L "$TMUX_SOCK" set -g pane-border-style 'fg=#585b70'
tmux -L "$TMUX_SOCK" set -g pane-active-border-style 'fg=#89b4fa'
# Split horizontally: top pane for k9s, bottom for deploy output.
tmux -L "$TMUX_SOCK" split-window -v -l 60% -t "${TMUX_SESSION}:0"

DEPLOY_FLAGS=""
[ "$RECREATE" = true ] && DEPLOY_FLAGS="$DEPLOY_FLAGS --recreate"
[ "$NO_PRELOAD" = true ] && DEPLOY_FLAGS="$DEPLOY_FLAGS --no-preload"

# Top pane: k9s -A. Pointed at our cluster context; k9s tolerates the
# context not existing yet and will pick it up when kind creates it.
tmux -L "$TMUX_SOCK" send-keys -t "${TMUX_SESSION}:0.0" \
    "while ! kubectl --context $KCTX cluster-info >/dev/null 2>&1; do sleep 1; done; k9s --context $KCTX -A" Enter

# Bottom pane: run the prep script, touch the ready flag on success, then
# stay alive (via cat) so the pane shows the final state until cleanup
# tears the session down.
DEPLOY_CMD="bash '$SCRIPT_DIR/deploy-homelab-kind.sh' --prep-only$DEPLOY_FLAGS && touch '$READY_FILE'; echo; echo '[demo orchestrator in control — Ctrl-C in the launching terminal to tear down]'; tail -f /dev/null"
tmux -L "$TMUX_SOCK" send-keys -t "${TMUX_SESSION}:0.1" "$DEPLOY_CMD" Enter

# ── background watcher: wait for ready flag, PF, chrome, hold, detach ──
# The watcher runs for the entire demo: it waits for the prep script to
# finish, starts port-forwards, pops chrome, holds for $HOLD with tmux
# still attached (so the recording shows tmux + chrome side-by-side),
# then kills the tmux session, which causes the `tmux attach` below to
# return and drops us into cleanup().
PF_FILE="$(mktemp -t homelab-demo-pfs.XXXXXX)"
(
    while [ ! -f "$READY_FILE" ]; do sleep 2; done

    kubectl --context "$KCTX" -n "$IMMICH_NS"  port-forward "svc/$IMMICH_SVC"  "$IMMICH_LOCAL:$IMMICH_PORT"  >/tmp/pf-immich.log 2>&1 &
    echo $! >> "$PF_FILE"
    kubectl --context "$KCTX" -n "$VAULT_NS"   port-forward "svc/$VAULT_SVC"   "$VAULT_LOCAL:$VAULT_PORT"    >/tmp/pf-vault.log 2>&1 &
    echo $! >> "$PF_FILE"
    kubectl --context "$KCTX" -n "$GRAFANA_NS" port-forward "svc/$GRAFANA_SVC" "$GRAFANA_LOCAL:$GRAFANA_PORT" >/tmp/pf-grafana.log 2>&1 &
    echo $! >> "$PF_FILE"

    for _ in $(seq 1 30); do
        if curl -sf -o /dev/null "http://localhost:$IMMICH_LOCAL"; then break; fi
        sleep 1
    done

    # Clean app window via an isolated profile dir. This never attaches
    # to the user's running chrome, and cleanup can pkill by that flag.
    "$CHROME" \
        --user-data-dir="$CHROME_PROFILE" \
        --no-first-run --no-default-browser-check \
        --new-window \
        --window-size=1400,900 \
        --window-position=80,80 \
        --app="http://localhost:$IMMICH_LOCAL" \
        >/dev/null 2>&1 &

    sleep "$HOLD"

    # Drop the attach below by killing the session; main script then
    # falls through into cleanup().
    tmux -L "$TMUX_SOCK" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
) &
WATCHER_PID=$!

# ── attach and let the demo play out ─────────────────────────────────────
log "attaching to tmux — chrome will pop automatically; hold=${HOLD}s"
( tmux -L "$TMUX_SOCK" attach -t "$TMUX_SESSION" ) || true

if [ -f "$PF_FILE" ]; then
    mapfile -t PF_PIDS < "$PF_FILE"
    rm -f "$PF_FILE"
fi

# cleanup() runs from the EXIT trap.
