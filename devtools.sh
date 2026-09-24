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

DEFAULT_IMAGE="ghcr.io/sphyrix/devtools:0.15.0@sha256:fec7d22888ebc5e79a496a7a322f1d6c3eb07af14ebe64083d9b5e3e47813d92"

# Resolve image, most specific wins: DEVTOOLS_IMAGE env > .project.toml [devtools] image > pin.
IMAGE="$DEFAULT_IMAGE"
if [ -f ".project.toml" ]; then
    _img=$(grep -E '^\s*image\s*=' .project.toml | head -1 | sed 's/.*=\s*"\(.*\)"/\1/' || true)
    [ -n "$_img" ] && IMAGE="$_img"
fi
IMAGE="${DEVTOOLS_IMAGE:-$IMAGE}"

TAILNET_KEY_ENV=""
if [ "${1:-}" = "tailnet-key" ]; then
    if [ "$#" -ne 2 ]; then
        echo "usage: devtools tailnet-key <env>" >&2
        exit 1
    fi
    TAILNET_KEY_ENV="$2"
fi

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
ENV_FILE="${DEVTOOLS_ENV_FILE:-}"
if [ -z "$ENV_FILE" ] && [ -f .env ]; then
    ENV_FILE=".env"
fi
if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
    echo "Error: DEVTOOLS_ENV_FILE=$ENV_FILE does not exist" >&2
    exit 1
fi
if [ -n "$TAILNET_KEY_ENV" ] && [ -z "$ENV_FILE" ]; then
    echo "Error: devtools tailnet-key needs DEVTOOLS_ENV_FILE or a project .env file" >&2
    exit 1
fi

ENV_ARGS=()
if [ -n "$ENV_FILE" ]; then
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
if [ -z "$TAILNET_KEY_ENV" ]; then
    exec docker run --rm \
        $TTY_FLAGS \
        -v "$(pwd):/project" \
        -w /project \
        ${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"} \
        ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
        ${TAILNET_FLAGS[@]+"${TAILNET_FLAGS[@]}"} \
        "$IMAGE" \
        "$@"
fi

resolve_file() {
    local path="$1" link
    case "$path" in
        /*) ;;
        *) path="$(pwd)/$path" ;;
    esac
    while [ -L "$path" ]; do
        link="$(readlink "$path")"
        case "$link" in
            /*) path="$link" ;;
            *) path="$(dirname "$path")/$link" ;;
        esac
    done
    printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}

ENV_REAL="$(resolve_file "$ENV_FILE")"
if ENV_MODE="$(stat -c '%a' "$ENV_REAL" 2>/dev/null)"; then
    :
else
    ENV_MODE="$(stat -f '%Lp' "$ENV_REAL")"
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devtools-tailnet-key.XXXXXX")"
COMMIT_FILE=""
cleanup_tailnet_key() {
    [ -z "$COMMIT_FILE" ] || rm -f "$COMMIT_FILE"
    rm -rf "$STAGE_DIR"
}
trap cleanup_tailnet_key EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$STAGE_DIR"
cp "$ENV_REAL" "$STAGE_DIR/env"
chmod 600 "$STAGE_DIR/env"

TAILNET_ENV_ARGS=(--env-file "$STAGE_DIR/env")
for var in GITHUB_REPOSITORY DOCKER_IMAGE IMAGE_TAG DOCKER_BUILD_ARGS DOCKER_BUILD_CONTEXT DOCKERFILE; do
    if [ -n "${!var:-}" ]; then
        TAILNET_ENV_ARGS+=(-e "${var}=${!var}")
    fi
done

set +e
docker run --rm \
    $TTY_FLAGS \
    -v "$(pwd):/project" \
    -v "$STAGE_DIR:/run/devtools-host" \
    -w /project \
    ${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"} \
    ${TAILNET_ENV_ARGS[@]+"${TAILNET_ENV_ARGS[@]}"} \
    "$IMAGE" \
    run tailnet-key "$TAILNET_KEY_ENV" -- --env-file /run/devtools-host/env
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

ENV_DIR="$(dirname "$ENV_REAL")"
COMMIT_FILE="$(mktemp "$ENV_DIR/.devtools-tailnet-key.XXXXXX")"
cp "$STAGE_DIR/env" "$COMMIT_FILE"
chmod "$ENV_MODE" "$COMMIT_FILE"
mv -f "$COMMIT_FILE" "$ENV_REAL"
COMMIT_FILE=""
echo "Updated $ENV_FILE with a fresh TS_AUTHKEY."
