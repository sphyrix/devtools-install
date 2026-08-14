#!/usr/bin/env bash
# devtools host wrapper — runs devtools commands inside the Docker container.
# Install to PATH via scripts/install.sh or the project init.sh bootstrap.
#
# CANONICAL COPY. github.com/sphyrix/devtools-install/devtools.sh must be kept byte-identical —
# RELEASE RULE: every devtools release bumps DEFAULT_IMAGE's tag here AND syncs the file to
# devtools-install in the same change. The pin is the version contract: an immutable version tag
# means no label-checking, no per-invocation pulls, and offline runs Just Work once the image is
# cached.
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/sphyrix/devtools:0.13.0@sha256:acb23b3d69c5f7495ffa2d2fe7c774adef40cb29f59fee65ceaf7a412db967bd"

# Resolve image, most specific wins: DEVTOOLS_IMAGE env > .project.toml [devtools] image > pin.
IMAGE="$DEFAULT_IMAGE"
if [ -f ".project.toml" ]; then
    _img=$(grep -E '^\s*image\s*=' .project.toml | head -1 | sed 's/.*=\s*"\(.*\)"/\1/' || true)
    [ -n "$_img" ] && IMAGE="$_img"
fi
IMAGE="${DEVTOOLS_IMAGE:-$IMAGE}"

# Kernel-TUN device/cap flags — ADR 001 addendum §5.5. Added only for `run <target>`
# invocations where <target> (the argument right after `run`) is listed in
# .project.toml's [tailnet].targets; every other invocation, and every non-tailnet
# target, is unchanged. Crude by design, matching this script's existing .project.toml
# parsing: a single-line, double-quoted `targets = [...]` array only (neither a
# multi-line array nor single-quoted TOML strings are recognised — document targets
# with double quotes on one line), and invocations that put global flags before `run`
# are out of scope — this script does not parse its own argument list.
TAILNET_FLAGS=()
if [ -f ".project.toml" ] && [ "${1:-}" = "run" ] && [ -n "${2:-}" ]; then
    _tn_target="$2"
    _tn_line=$(sed -n '/^\[tailnet\]/,/^\[/p' .project.toml | grep -E '^\s*targets\s*=' | head -1 || true)
    if [ -n "$_tn_line" ]; then
        while IFS= read -r _tn_t; do
            if [ "$_tn_t" = "$_tn_target" ]; then
                TAILNET_FLAGS=(--device /dev/net/tun --cap-add NET_ADMIN)
                break
            fi
        done < <(echo "$_tn_line" | grep -oE '"[^"]*"' | tr -d '"')
    fi
fi

# Pinned tags are immutable, so pull only when absent. Floating tags (:latest, :main) are refreshed
# best-effort — offline just uses the cached image instead of dying.
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "devtools image not found, pulling $IMAGE..." >&2
    docker pull "$IMAGE" >&2
else
    case "$IMAGE" in
        *:latest|*:main)
            docker pull "$IMAGE" >&2 || echo "warning: could not refresh $IMAGE (offline?); using cached image" >&2
            ;;
    esac
fi

# A TTY is needed for interactive `devtools init`, but demanding one breaks every non-interactive
# caller (CI, scripts, agents) — attach only if we have one.
TTY_FLAGS=""
if [ -t 0 ] && [ -t 1 ]; then
    TTY_FLAGS="-it"
fi

# THE secrets interface (same contract as the generated proxy's _ensure): recipes read env vars
# only; hand them over as a KEY=VALUE file. DEVTOOLS_ENV_FILE wins; a plain .env in the project
# root is the default. With enough permissions and the right env file, anything CI does is
# reproducible from a laptop: `DEVTOOLS_ENV_FILE=prod.env devtools run <target>`.
ENV_ARGS=()
ENV_FILE="${DEVTOOLS_ENV_FILE:-}"
if [ -z "$ENV_FILE" ] && [ -f .env ]; then
    ENV_FILE=".env"
fi
if [ -n "$ENV_FILE" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo "Error: DEVTOOLS_ENV_FILE=$ENV_FILE does not exist" >&2
        exit 1
    fi
    ENV_ARGS+=(--env-file "$ENV_FILE")
fi

# Pass through docker-target inputs (same list as the proxy's _ensure) so docker recipes derive
# image paths identically in both entry paths. DOCKER_BUILD_CONTEXT/DOCKERFILE point the docker
# addon at a Dockerfile that isn't the project root's (a build context, NOT docker's own reserved
# DOCKER_CONTEXT daemon selector — see justfiles/addons/docker.just).
for var in GITHUB_REPOSITORY DOCKER_IMAGE IMAGE_TAG DOCKER_BUILD_ARGS DOCKER_BUILD_CONTEXT DOCKERFILE; do
    if [ -n "${!var:-}" ]; then
        ENV_ARGS+=(-e "${var}=${!var}")
    fi
done

# Mount the host Docker socket (when present) so docker addon targets work from here too.
MOUNT_ARGS=()
if [ -S /var/run/docker.sock ]; then
    MOUNT_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi

# ${arr[@]+...} guards: empty-array expansion under `set -u` is an "unbound variable" error on
# bash 3.2 (macOS default) — the guard expands to nothing there instead.
exec docker run --rm \
    $TTY_FLAGS \
    -v "$(pwd):/project" \
    -w /project \
    ${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"} \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    ${TAILNET_FLAGS[@]+"${TAILNET_FLAGS[@]}"} \
    "$IMAGE" \
    "$@"
