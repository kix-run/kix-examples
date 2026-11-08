#!/usr/bin/env bash
# kind-local-registry.sh — Manage a local Docker registry for Kind image preloading.
#
# Instead of `kind load docker-image` (which does docker-save→ctr-import per image,
# ~4-5min for 32 images), images are pushed to a local registry once. Kind nodes pull
# from it via containerd mirror config — near-instant, digest-preserving, incremental.
#
# Usage:
#   ./how-to/homelab/demos/kind-local-registry.sh setup
#   ./how-to/homelab/demos/kind-local-registry.sh push [--cluster <name>] [--flake <path>]
#   ./how-to/homelab/demos/kind-local-registry.sh preload [--cluster <name>] [--flake <path>] [--kind-name <name>]
#   ./how-to/homelab/demos/kind-local-registry.sh status
#   ./how-to/homelab/demos/kind-local-registry.sh kind-config [--name <cluster-name>]
#
# Subcommands:
#   setup       Start a registry:2 container on port 5001 (idempotent)
#   push        Pull kix images into Docker, re-tag, push to local registry
#   preload     Pre-pull all images into Kind nodes from local registry
#   status      Show registry state (running, image count, disk usage)
#   kind-config Output Kind cluster YAML with containerd mirror config
#
# The push step is incremental: images already in the registry are skipped.
# Digest-pinned images (e.g. cilium) resolve correctly because containerd
# pulls by digest from the mirror, and the registry serves the original content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REGISTRY_NAME="kind-registry"
REGISTRY_PORT=5001
REGISTRY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kind-registry"
CONFIG_DIR="$REGISTRY_DIR/containerd-certs.d"

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log() { echo -e "${B}==>${N} $*"; }
ok()  { echo -e "${G}✓${N} $*"; }
warn(){ echo -e "${Y}!${N} $*" >&2; }
die() { echo -e "${R}✗${N} $*" >&2; exit 1; }

# ── helpers ────────────────────────────────────────────────────────────────

# Parse an image reference into components.
# Sets globals: _REG, _PATH, _TAG, _DIGEST
parse_image_ref() {
    local image="$1"
    _DIGEST=""
    _TAG="latest"

    # Extract digest
    if [[ "$image" == *@sha256:* ]]; then
        _DIGEST="${image#*@}"
        image="${image%%@*}"
    fi

    # Extract tag (last :component that isn't a port)
    if [[ "$image" == *:* ]]; then
        local candidate="${image##*:}"
        if [[ "$candidate" != */* ]]; then
            _TAG="$candidate"
            image="${image%:*}"
        fi
    fi

    # Extract registry vs path
    local first="${image%%/*}"
    if [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [[ "$first" == localhost ]]; then
        _REG="$first"
        _PATH="${image#*/}"
    else
        _REG="docker.io"
        if [[ "$image" == */* ]]; then
            _PATH="$image"
        else
            _PATH="library/$image"
        fi
    fi
}

ensure_kind_network() {
    if docker network inspect kind &>/dev/null; then
        if ! docker inspect "$REGISTRY_NAME" \
                -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
                | grep -q 'kind'; then
            log "connecting registry to 'kind' docker network"
            docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true
        fi
    fi
}

# ── setup ──────────────────────────────────────────────────────────────────

cmd_setup() {
    if docker inspect "$REGISTRY_NAME" &>/dev/null; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null)" = "true" ]; then
            ok "registry '$REGISTRY_NAME' already running on port $REGISTRY_PORT"
            ensure_kind_network
            return 0
        fi
        log "starting stopped registry container"
        docker start "$REGISTRY_NAME" >/dev/null
    else
        log "creating registry container '$REGISTRY_NAME' on port $REGISTRY_PORT"
        mkdir -p "$REGISTRY_DIR/data"
        docker run -d \
            --name "$REGISTRY_NAME" \
            --restart=always \
            -p "127.0.0.1:${REGISTRY_PORT}:5000" \
            -v "$REGISTRY_DIR/data:/var/lib/registry" \
            registry:2 >/dev/null
    fi
    ensure_kind_network
    ok "registry running at localhost:$REGISTRY_PORT"
}

# ── push ───────────────────────────────────────────────────────────────────

cmd_push() {
    local cluster="homelab-kind"
    local flake="."

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster) cluster="$2"; shift 2 ;;
            --flake)   flake="$2"; shift 2 ;;
            *) die "unknown push option: $1" ;;
        esac
    done

    # Verify registry is running
    if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null)" != "true" ]; then
        die "registry not running — run '$0 setup' first"
    fi

    cd "$ROOT_DIR"

    # ── extract image list ─────────────────────────────────────────────
    log "extracting image list via: kix --no-cache --flake $flake -q images $cluster"
    mapfile -t IMAGES < <(kix --no-cache --flake "$flake" -q images "$cluster" 2>/dev/null) \
        || IMAGES=()
    [ ${#IMAGES[@]} -gt 0 ] || die "kix images returned no images"
    ok "${#IMAGES[@]} images found"

    # ── check for path collisions across registries ────────────────────
    # We push images without the registry prefix so containerd mirrors work.
    # If two registries have the same path:tag, we can't disambiguate.
    declare -A PATH_OWNER
    for img in "${IMAGES[@]}"; do
        parse_image_ref "$img"
        local key="${_PATH}:${_TAG}"
        if [[ -n "${PATH_OWNER[$key]:-}" ]] && [[ "${PATH_OWNER[$key]}" != "$_REG" ]]; then
            die "path collision: '$key' exists in both $_REG and ${PATH_OWNER[$key]}. Cannot use mirror approach."
        fi
        PATH_OWNER[$key]="$_REG"
    done

    # ── pull images into Docker ────────────────────────────────────────
    log "pulling ${#IMAGES[@]} images into Docker (parallel)"
    printf '%s\n' "${IMAGES[@]}" | python3 "$SCRIPT_DIR/docker-pull-parallel.py" \
        || warn "some image(s) failed to pull"

    # Docker stores digest-pinned images without a tag. Create tag aliases.
    for img in "${IMAGES[@]}"; do
        if [[ "$img" == *@sha256:* ]]; then
            docker tag "$img" "${img%%@sha256:*}" 2>/dev/null || true
        fi
    done

    # ── push to local registry (incremental) ───────────────────────────
    log "pushing images to local registry (localhost:$REGISTRY_PORT)"
    local push_count=0 skip_count=0 fail_count=0
    local total=${#IMAGES[@]}
    declare -A SEEN_PUSH
    declare -A REGISTRIES_SEEN

    for img in "${IMAGES[@]}"; do
        parse_image_ref "$img"
        local local_ref="localhost:${REGISTRY_PORT}/${_PATH}:${_TAG}"
        local source_ref="${img%%@sha256:*}"

        REGISTRIES_SEEN[$_REG]=1

        # Deduplicate (digest-pinned and tag-only may map to same local ref)
        if [[ -n "${SEEN_PUSH[$local_ref]:-}" ]]; then
            continue
        fi
        SEEN_PUSH[$local_ref]=1

        # Check if manifest already exists in registry (HEAD is fast). A
        # digest-pinned image is looked up by digest: the tag may be there
        # from an older run through the docker path, with another digest.
        local ref_to_check="${_TAG}"
        [[ "$img" == *@sha256:* ]] && ref_to_check="${_DIGEST}"
        if curl -sf --head \
            "http://localhost:${REGISTRY_PORT}/v2/${_PATH}/manifests/${ref_to_check}" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
            >/dev/null 2>&1; then
            skip_count=$((skip_count + 1))
            printf "\r  [%d/%d] skipped: %-50s" "$((push_count + skip_count + fail_count))" "$total" "${_PATH}:${_TAG}"
            continue
        fi

        # A digest-pinned reference names a multi-arch index. The docker
        # daemon stores one platform's image and re-pushing it changes the
        # digest, so a node pulling by the original digest gets a 404 from
        # the mirror. crane copies the index as is; the docker path stays
        # for tag-only references.
        if [[ "$img" == *@sha256:* ]]; then
            command -v crane >/dev/null 2>&1 \
                || die "$img is pinned by digest; install crane (go-containerregistry) so the mirror keeps the index digest"
            if crane copy --insecure "$img" "$local_ref" >/dev/null 2>&1; then
                push_count=$((push_count + 1))
            else
                fail_count=$((fail_count + 1))
                warn "failed to copy: $img → $local_ref"
            fi
        elif docker tag "$source_ref" "$local_ref" 2>/dev/null && \
           docker push "$local_ref" >/dev/null 2>&1; then
            push_count=$((push_count + 1))
        else
            fail_count=$((fail_count + 1))
            warn "failed to push: $source_ref → $local_ref"
        fi
        printf "\r  [%d/%d] pushed: %-50s" "$((push_count + skip_count + fail_count))" "$total" "${_PATH}:${_TAG}"
    done
    echo

    [ "$fail_count" -eq 0 ] || warn "$fail_count image(s) failed to push"
    ok "registry: $push_count pushed, $skip_count skipped (already present)"

    # ── generate containerd mirror config ──────────────────────────────
    log "generating containerd mirror config at $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
    for reg in "${!REGISTRIES_SEEN[@]}"; do
        mkdir -p "$CONFIG_DIR/$reg"
        cat > "$CONFIG_DIR/$reg/hosts.toml" <<TOML
server = "https://$reg"

[host."http://${REGISTRY_NAME}:5000"]
  capabilities = ["pull", "resolve"]
TOML
    done
    ok "mirror config for ${#REGISTRIES_SEEN[@]} registries: ${!REGISTRIES_SEEN[*]}"
}

# ── preload ────────────────────────────────────────────────────────────────
# Pre-pull all kix images into Kind nodes from the local registry.
# Uses `ctr` to pull from the registry over plain HTTP (no mirror config
# needed), then tags each image with its original name so kubelet finds it.
# Works on any Kind cluster — the only requirement is that the registry
# container is on the `kind` Docker network.

cmd_preload() {
    local cluster="homelab-kind"
    local flake="."
    local kind_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster)   cluster="$2"; shift 2 ;;
            --flake)     flake="$2"; shift 2 ;;
            --kind-name) kind_name="$2"; shift 2 ;;
            *) die "unknown preload option: $1" ;;
        esac
    done

    # Verify registry is running and on the kind network
    if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null)" != "true" ]; then
        die "registry not running — run '$0 setup' first"
    fi
    ensure_kind_network

    cd "$ROOT_DIR"

    # ── get image list ─────────────────────────────────────────────────
    log "extracting image list via: kix --no-cache --flake $flake -q images $cluster"
    mapfile -t IMAGES < <(kix --no-cache --flake "$flake" -q images "$cluster" 2>/dev/null) \
        || IMAGES=()
    [ ${#IMAGES[@]} -gt 0 ] || die "kix images returned no images"
    ok "${#IMAGES[@]} images found"

    # ── find Kind node containers ──────────────────────────────────────
    if [ -z "$kind_name" ]; then
        local candidates
        mapfile -t candidates < <(kind get clusters 2>/dev/null || true)
        if [ ${#candidates[@]} -eq 1 ]; then
            kind_name="${candidates[0]}"
            log "auto-detected Kind cluster: $kind_name"
        elif [ ${#candidates[@]} -gt 1 ]; then
            die "multiple Kind clusters found (${candidates[*]}). Pass --kind-name <name>"
        else
            die "no Kind clusters found. Create one first."
        fi
    fi

    mapfile -t NODES < <(kind get nodes --name "$kind_name" 2>/dev/null) || NODES=()
    [ ${#NODES[@]} -gt 0 ] || die "no nodes found for Kind cluster '$kind_name'"
    ok "${#NODES[@]} node(s): ${NODES[*]}"

    # ── build pull+tag commands per image ──────────────────────────────
    # For each image we:
    #   1. ctr pull from kind-registry:5000/<path>:<tag> (plain HTTP, local network)
    #   2. ctr images tag → original ref (so kubelet/crictl finds it by name)
    #   3. For digest-pinned images, also tag as ref@sha256:...
    declare -A SEEN_REF
    local pull_cmds=()

    for img in "${IMAGES[@]}"; do
        parse_image_ref "$img"
        local registry_ref="${REGISTRY_NAME}:5000/${_PATH}:${_TAG}"
        local original_ref="${_REG}/${_PATH}:${_TAG}"

        # Deduplicate
        if [[ -n "${SEEN_REF[$registry_ref]:-}" ]]; then
            continue
        fi
        SEEN_REF[$registry_ref]=1

        # Build a script that pulls + tags in one exec (avoids per-image docker exec overhead)
        local tag_cmd="ctr -n k8s.io images tag --force '${registry_ref}' '${original_ref}' >/dev/null 2>&1"
        if [[ -n "$_DIGEST" ]]; then
            tag_cmd="${tag_cmd} && ctr -n k8s.io images tag --force '${registry_ref}' '${original_ref}@${_DIGEST}' >/dev/null 2>&1"
        fi
        pull_cmds+=("${registry_ref}|${tag_cmd}")
    done

    local total=${#pull_cmds[@]}

    # ── pre-pull images on each node ───────────────────────────────────
    for node in "${NODES[@]}"; do
        log "preloading $total images on node '$node' from local registry"
        local done_count=0 fail_count=0
        local max_parallel=5
        local batch_pids=() batch_refs=()

        for entry in "${pull_cmds[@]}"; do
            local ref="${entry%%|*}"
            local tag_cmd="${entry#*|}"

            # Check if image already exists on node (skip if present)
            # Pull + tag in a single docker exec; ctr pull --plain-http handles insecure registry
            (
                docker exec "$node" ctr -n k8s.io images pull --plain-http "$ref" >/dev/null 2>&1 \
                    && docker exec "$node" bash -c "$tag_cmd"
            ) &
            batch_pids+=($!)
            batch_refs+=("$ref")

            if [ ${#batch_pids[@]} -ge $max_parallel ]; then
                for i in "${!batch_pids[@]}"; do
                    if wait "${batch_pids[$i]}" 2>/dev/null; then
                        done_count=$((done_count + 1))
                    else
                        done_count=$((done_count + 1))
                        fail_count=$((fail_count + 1))
                        warn "failed: ${batch_refs[$i]}"
                    fi
                    printf "\r  [%d/%d] images loaded" "$done_count" "$total"
                done
                batch_pids=()
                batch_refs=()
            fi
        done

        # Wait for remaining batch
        for i in "${!batch_pids[@]}"; do
            if wait "${batch_pids[$i]}" 2>/dev/null; then
                done_count=$((done_count + 1))
            else
                done_count=$((done_count + 1))
                fail_count=$((fail_count + 1))
                warn "failed: ${batch_refs[$i]}"
            fi
            printf "\r  [%d/%d] images loaded" "$done_count" "$total"
        done
        echo

        if [ "$fail_count" -gt 0 ]; then
            warn "$fail_count image(s) failed on $node"
        fi
        ok "node '$node': $((done_count - fail_count))/$total images preloaded"
    done
}

# ── status ─────────────────────────────────────────────────────────────────

cmd_status() {
    echo "Registry: $REGISTRY_NAME"

    if ! docker inspect "$REGISTRY_NAME" &>/dev/null; then
        echo "State:    not created"
        return 1
    fi

    local running
    running=$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null)
    echo "Running:  $running"
    echo "Port:     localhost:$REGISTRY_PORT"

    if [ "$running" = "true" ]; then
        local catalog repos
        catalog=$(curl -s "http://localhost:${REGISTRY_PORT}/v2/_catalog" 2>/dev/null || echo '{}')
        repos=$(echo "$catalog" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('repositories',[])))" 2>/dev/null \
            || echo "?")
        echo "Images:   $repos repositories"

        if [ -d "$REGISTRY_DIR/data" ]; then
            echo "Disk:     $(du -sh "$REGISTRY_DIR/data" 2>/dev/null | cut -f1)"
        fi

        local networks
        networks=$(docker inspect "$REGISTRY_NAME" \
            -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)
        echo "Networks: ${networks:-none}"
    fi

    if [ -d "$CONFIG_DIR" ]; then
        local regs
        regs=$(ls "$CONFIG_DIR" 2>/dev/null | tr '\n' ' ')
        echo "Mirrors:  ${regs:-none}"
    fi
}

# ── kind-config ────────────────────────────────────────────────────────────

cmd_kind_config() {
    local cluster_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) cluster_name="$2"; shift 2 ;;
            *) die "unknown kind-config option: $1" ;;
        esac
    done

    if [ ! -d "$CONFIG_DIR" ]; then
        die "no mirror config found — run '$0 push' first to generate it"
    fi

    local name_line=""
    [ -n "$cluster_name" ] && name_line="name: $cluster_name"

    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
${name_line}
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        serializeImagePulls: false
        maxParallelImagePulls: 5
    # Mount the local registry mirror config into the node so containerd
    # resolves images from the local registry before hitting the network.
    extraMounts:
      - hostPath: $CONFIG_DIR
        containerPath: /etc/containerd/certs.d
        readOnly: true
# Tell containerd to use the hosts directory for registry resolution.
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
}

# ── main ───────────────────────────────────────────────────────────────────

case "${1:-help}" in
    setup)       shift; cmd_setup "$@" ;;
    push)        shift; cmd_push "$@" ;;
    preload)     shift; cmd_preload "$@" ;;
    status)      shift; cmd_status "$@" ;;
    kind-config) shift; cmd_kind_config "$@" ;;
    -h|--help|help)
        cat <<'USAGE'
Usage: kind-local-registry.sh <command> [options]

Manage a local Docker registry for fast Kind image preloading.
Images are pushed once; Kind nodes pull via containerd mirrors.

Commands:
  setup                Start registry container on port 5001 (idempotent)
  push [OPTIONS]       Pull kix images and push to local registry
  preload [OPTIONS]    Pre-pull all images into Kind nodes from registry
  status               Show registry state
  kind-config [--name] Output Kind cluster config with registry mirrors

Push options:
  --cluster <name>     kix cluster name (default: homelab-kind)
  --flake <path>       flake path for kix (default: .)

Preload options:
  --cluster <name>     kix cluster name (default: homelab-kind)
  --flake <path>       flake path for kix (default: .)
  --kind-name <name>   Kind cluster name (auto-detected if only one exists)

Kind-config options:
  --name <name>        cluster name to embed in config

Workflow:
  1. ./how-to/homelab/demos/kind-local-registry.sh setup
  2. ./how-to/homelab/demos/kind-local-registry.sh push --cluster homelab-kind --flake .
  3. ./how-to/homelab/demos/kind-local-registry.sh kind-config --name kix-homelab > /tmp/kind.yaml
  4. kind create cluster --config /tmp/kind.yaml
  5. ./how-to/homelab/demos/kind-local-registry.sh setup      # connect registry to kind network
  6. ./how-to/homelab/demos/kind-local-registry.sh preload     # pre-pull into nodes (optional)
USAGE
        ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
