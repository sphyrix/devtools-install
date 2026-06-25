#!/usr/bin/env bash
# devtools host wrapper — runs devtools commands inside the public Docker image.
# Installed to PATH as `devtools` via install.sh (or the project init.sh bootstrap).
#
# The devtools binary is a containerized toolkit: it ships with bundled `just`
# recipes (/opt/devtools/justfiles) and expects to run inside its image, so this
# wrapper invokes it via `docker run` rather than executing a bare host binary.
set -euo pipefail

# Pinned image version. The wrapper re-pulls when the local image's
# org.opencontainers.image.version label does not match this value.
DEVTOOLS_VERSION="${DEVTOOLS_VERSION:-v0.3.6}"

# Public image (repo source stays private; the image package is public).
DEFAULT_IMAGE="ghcr.io/sphyrix/devtools:latest"

# Resolve image: prefer .project.toml in cwd, fall back to default.
IMAGE="${DEVTOOLS_IMAGE:-$DEFAULT_IMAGE}"
if [ -f ".project.toml" ]; then
    _img=$(grep -E '^\s*image\s*=' .project.toml | head -1 | sed 's/.*=\s*"\(.*\)"/\1/' || true)
    [ -n "$_img" ] && IMAGE="$_img"
fi

# Check if image is present and up to date.
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "devtools image not found, pulling $IMAGE..." >&2
    docker pull "$IMAGE" >&2
else
    LOCAL_VERSION=$(docker inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
    if [ -n "$DEVTOOLS_VERSION" ] && [ "$LOCAL_VERSION" != "$DEVTOOLS_VERSION" ]; then
        echo "devtools image out of date (${LOCAL_VERSION:-unknown} -> ${DEVTOOLS_VERSION}), pulling..." >&2
        docker pull "$IMAGE" >&2
    fi
fi

exec docker run --rm \
    -it \
    -v "$(pwd):/project" \
    -w /project \
    "$IMAGE" \
    "$@"
