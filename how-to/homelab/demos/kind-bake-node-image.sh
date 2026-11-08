#!/usr/bin/env bash
# kind-bake-node-image.sh — Build a Kind node image with kix images pre-loaded
# into containerd's store. Clusters created with this image skip the entire
# pull + kind-load phase (~5min → ~30s).
#
# Usage:
#   ./how-to/homelab/demos/kind-bake-node-image.sh [OPTIONS]
#
# Options:
#   --cluster <name>    kix cluster name for `kix images` (default: homelab-kind)
#   --flake <path>      flake path for kix (default: .)
#   --tag <tag>         output image tag (default: kindest/node-kix-<cluster>:latest)
#   --base <image>      base Kind node image (default: auto-detect from docker)
#   --force             rebuild even if image hash matches
#   -h, --help          show this help
#
# The script stores an image-list hash as a Docker label on the built image.
# On subsequent runs, if the hash matches, it skips the rebuild. Pass --force
# to override.
#
# How it works:
#   1. Run `kix images` to get the image list
#   2. Pull all images into Docker (parallel)
#   3. Create a temporary kind cluster
#   4. Load images via `kind load docker-image` (preserves digests for
#      signature-pinned images like cilium)
#   5. Commit the node container as the output image
#   6. Delete the temporary cluster
#
# Other demo scripts detect the baked image automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER="homelab-kind"
FLAKE="."
TAG=""
BASE_IMAGE=""
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --cluster) shift_next=cluster ;;
        --flake)   shift_next=flake ;;
        --tag)     shift_next=tag ;;
        --base)    shift_next=base ;;
        --force)   FORCE=true ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *)
            case "${shift_next:-}" in
                cluster) CLUSTER="$arg"; shift_next="" ;;
                flake)   FLAKE="$arg"; shift_next="" ;;
                tag)     TAG="$arg"; shift_next="" ;;
                base)    BASE_IMAGE="$arg"; shift_next="" ;;
                *) echo "unknown flag: $arg" >&2; exit 2 ;;
            esac
            ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log() { echo -e "${B}==>${N} $*"; }
ok()  { echo -e "${G}✓${N} $*"; }
warn(){ echo -e "${Y}!${N} $*"; }
die() { echo -e "${R}✗${N} $*" >&2; exit 1; }

# ── defaults ────────────────────────────────────────────────────────────
[ -z "$TAG" ] && TAG="kindest/node-kix-${CLUSTER}:latest"

if [ -z "$BASE_IMAGE" ]; then
    BASE_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep '^kindest/node:v' | sort -V | tail -1 || true)"
    if [ -z "$BASE_IMAGE" ]; then
        die "no kindest/node image found in Docker — create a kind cluster once first, or pass --base"
    fi
    log "auto-detected base image: $BASE_IMAGE"
fi

BAKE_CLUSTER="kix-bake-$$"
cleanup() {
    kind delete cluster --name "$BAKE_CLUSTER" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── extract image list ──────────────────────────────────────────────────
log "extracting image list via: kix --no-cache --flake $FLAKE -q images $CLUSTER"
mapfile -t IMAGES < <(kix --no-cache --flake "$FLAKE" -q images "$CLUSTER" 2>/dev/null) \
    || IMAGES=()
[ ${#IMAGES[@]} -gt 0 ] || die "kix images returned no images"
ok "${#IMAGES[@]} images found"

# ── check if rebuild needed ─────────────────────────────────────────────
IMAGE_HASH="$(printf '%s\n' "${IMAGES[@]}" | sort | sha256sum | cut -d' ' -f1)"
if [ "$FORCE" = false ]; then
    EXISTING_HASH="$(docker inspect --format='{{index .Config.Labels "kix.image-hash"}}' "$TAG" 2>/dev/null || true)"
    if [ "$EXISTING_HASH" = "$IMAGE_HASH" ]; then
        ok "baked image '$TAG' is up to date (hash: ${IMAGE_HASH:0:12}…)"
        exit 0
    fi
fi

log "building baked node image '$TAG' (hash: ${IMAGE_HASH:0:12}…)"

# ── pull images into docker ─────────────────────────────────────────────
log "pulling ${#IMAGES[@]} images (parallel)"
printf '%s\n' "${IMAGES[@]}" | python3 "$SCRIPT_DIR/docker-pull-parallel.py" \
    || warn "some image(s) failed to pull"

# Docker stores digest-pinned images (e.g. img:tag@sha256:...) without a tag —
# they show up as <none>. kind load needs the tag to exist, so create aliases.
for img in "${IMAGES[@]}"; do
    if [[ "$img" == *@sha256:* ]]; then
        tag_only="${img%%@sha256:*}"
        docker tag "$img" "$tag_only" 2>/dev/null || true
    fi
done

# Build deduplicated list of tag-only refs.
declare -A SEEN_TAGS
TAGGED_IMAGES=()
for img in "${IMAGES[@]}"; do
    tag_only="${img%%@sha256:*}"
    if [ -z "${SEEN_TAGS[$tag_only]:-}" ]; then
        SEEN_TAGS[$tag_only]=1
        TAGGED_IMAGES+=("$tag_only")
    fi
done

# ── create temporary kind cluster ───────────────────────────────────────
log "creating temporary kind cluster '$BAKE_CLUSTER'"
KIND_CONFIG="$(mktemp -t kix-bake.XXXXXX.yaml)"
cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $BAKE_CLUSTER
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
EOF
kind create cluster --name "$BAKE_CLUSTER" --config "$KIND_CONFIG" --image "$BASE_IMAGE"
rm -f "$KIND_CONFIG"

# ── load images via kind load (preserves digests) ───────────────────────
# This is the same approach as deploy-homelab-kind.sh's preload phase.
# kind load docker-image handles overlayfs whiteouts and digest-pinned
# images (e.g. cilium) correctly, unlike raw `docker save | ctr import`.
log "loading ${#TAGGED_IMAGES[@]} images into kind cluster (parallel)"
LOAD_PIDS=()
LOAD_TOTAL=${#TAGGED_IMAGES[@]}
LOAD_DONE=0
LOAD_FAIL=0
for img in "${TAGGED_IMAGES[@]}"; do
    kind load docker-image --name "$BAKE_CLUSTER" "$img" >/dev/null 2>&1 &
    LOAD_PIDS+=($!)
done
for pid in "${LOAD_PIDS[@]}"; do
    if wait "$pid"; then
        LOAD_DONE=$((LOAD_DONE + 1))
    else
        LOAD_DONE=$((LOAD_DONE + 1))
        LOAD_FAIL=$((LOAD_FAIL + 1))
    fi
    printf "\r  loaded %d/%d images" "$LOAD_DONE" "$LOAD_TOTAL"
done
echo
[ "$LOAD_FAIL" -eq 0 ] || warn "$LOAD_FAIL image(s) failed to load"

# Step 2: For digest-pinned images, re-run kind load with the full
# tag@sha256:... ref so containerd also has the digest-addressed entry.
for img in "${IMAGES[@]}"; do
    if [[ "$img" == *@sha256:* ]]; then
        kind load docker-image --name "$BAKE_CLUSTER" "$img" >/dev/null 2>&1 \
            || warn "failed to add digest ref for $img"
    fi
done
ok "image load complete"

# ── clean kubeadm state before commit ───────────────────────────────────
# docker commit captures everything — including kubeadm certs, kubeconfigs,
# and etcd data from the bake cluster. A fresh `kind create cluster` runs
# kubeadm init again, which fails if it finds stale state (wrong hostname
# in certs/kubeconfigs). Wipe everything except containerd's image store.
NODE_CONTAINER="${BAKE_CLUSTER}-control-plane"
log "cleaning kubeadm state from node (keeping containerd images)"
docker exec "$NODE_CONTAINER" bash -c '
    # Stop kubelet so kubeadm state is not actively used
    systemctl stop kubelet 2>/dev/null || true

    # Remove kubeadm config state that embeds the bake cluster hostname.
    # kubeadm init on the new cluster will regenerate all of these.
    rm -rf /etc/kubernetes/pki
    rm -rf /etc/kubernetes/manifests
    rm -f /etc/kubernetes/admin.conf
    rm -f /etc/kubernetes/super-admin.conf
    rm -f /etc/kubernetes/kubelet.conf
    rm -f /etc/kubernetes/controller-manager.conf
    rm -f /etc/kubernetes/scheduler.conf
    rm -rf /var/lib/etcd

    # Remove CNI config (will be recreated by kind)
    rm -rf /etc/cni/net.d/*

    # DO NOT run crictl rmp or remove /var/lib/kubelet — that triggers
    # containerd GC which wipes the preloaded images.
' 2>/dev/null || warn "some cleanup steps failed (non-fatal)"

# ── commit node container as baked image ────────────────────────────────
log "committing container '$NODE_CONTAINER' as '$TAG'"
docker commit \
    --change "LABEL kix.image-hash=$IMAGE_HASH" \
    "$NODE_CONTAINER" "$TAG" >/dev/null

ok "baked node image ready: $TAG"
echo
echo "  Use with kind:"
echo "    kind create cluster --image $TAG"
echo
echo "  Or in deploy scripts, the baked image is auto-detected."

# cleanup() deletes the temporary kind cluster via the EXIT trap.
