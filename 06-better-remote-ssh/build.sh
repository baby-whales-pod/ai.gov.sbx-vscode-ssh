#!/bin/bash
set -euo pipefail

# Build the Remote-SSH template from a Docker-provided sandbox template.
#
#   ./build.sh                    build locally into the sbx image store (no push)
#   ./build.sh push               build + push to Docker Hub (linux/amd64,linux/arm64)
#   ./build.sh push linux/arm64   push for specific platform(s) only (faster)
#
# Both produce the SAME tag ($DOCKER_HANDLE/$NAME:$TAG), so `sbx run -t` uses the
# local copy when present and pulls from Docker Hub otherwise. Bump TAG in
# config.env before pushing a new version.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -o allexport; . "$KIT_DIR/config.env"; set +o allexport

IMAGE="${DOCKER_HANDLE}/${NAME}:${TAG}"
BASE_IMAGE="${BASE_IMAGE:-docker/sandbox-templates:claude-code-docker}"
MODE="${1:-local}"

echo "Image: $IMAGE"
echo "Base:  $BASE_IMAGE"
echo "Mode:  $MODE"
echo

case "$MODE" in
  push)
    # Multi-arch goes straight to the registry (can't be --load'd locally).
    PLATFORMS="${2:-linux/amd64,linux/arm64}"
    echo "Platforms: $PLATFORMS"
    docker buildx build \
      --platform "$PLATFORMS" \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      -t "$IMAGE" \
      --push \
      "$KIT_DIR"
    echo
    echo "✅ Pushed $IMAGE — use it anywhere with ./start.sh (sbx pulls it)."
    ;;
  local)
    # OCI tar (not --load): the image only needs to reach the sbx store, not the
    # desktop Docker daemon. sbx template load accepts buildx OCI/docker tars.
    TAR="$(mktemp -t sbx-remote-ssh.XXXXXX.tar)"
    trap 'rm -f "$TAR"' EXIT
    docker buildx build \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      -t "$IMAGE" \
      -o "type=oci,dest=$TAR" \
      "$KIT_DIR"
    sbx template load "$TAR"
    echo
    echo "✅ Loaded $IMAGE into the sbx store — run ./start.sh [WORKSPACE]."
    sbx template ls 2>/dev/null | grep -E "REPOSITORY|${NAME}" || true
    ;;
  *)
    echo "Unknown mode '$MODE'. Use: ./build.sh [local|push]" >&2
    exit 1
    ;;
esac
