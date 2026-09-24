#!/usr/bin/env bash
# Installs the devtools host wrapper and offers to install Docker when missing.
set -euo pipefail

DEVTOOLS_RAW_BASE="${DEVTOOLS_RAW_BASE:-https://raw.githubusercontent.com/sphyrix/devtools-install/main}"
DOCKER_INSTALL_URL="${DEVTOOLS_DOCKER_INSTALL_URL:-https://get.docker.com}"
INSTALL_DIR="${DEVTOOLS_INSTALL_DIR:-$HOME/.local/bin}"
WRAPPER_URL="$DEVTOOLS_RAW_BASE/devtools.sh"
DEST="$INSTALL_DIR/devtools"
TEMP_FILE=""

cleanup() {
    [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
}
trap cleanup EXIT

die() {
    echo "Error: $*" >&2
    exit 1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "installing Docker needs root privileges; install Docker manually and rerun this command"
    fi
}

confirm_docker_install() {
    local policy answer
    policy="${DEVTOOLS_INSTALL_DOCKER:-ask}"
    case "$policy" in
        1 | yes | YES | true | TRUE) return 0 ;;
        0 | no | NO | false | FALSE) return 1 ;;
        ask) ;;
        *) die "DEVTOOLS_INSTALL_DOCKER must be ask, yes, or no" ;;
    esac

    if ! { exec 3</dev/tty; } 2>/dev/null; then
        die "Docker is missing and no interactive terminal is available; install Docker manually or rerun with DEVTOOLS_INSTALL_DOCKER=yes"
    fi
    printf 'Docker is required but was not found. Install it now? [y/N] ' >/dev/tty
    read -r answer <&3 || answer=""
    exec 3<&-
    case "$answer" in
        y | Y | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

install_docker_linux() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        die "automatic Docker installation is unavailable inside WSL; install Docker Desktop with WSL integration, then rerun this command"
    fi

    if command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --needed --noconfirm docker
        command -v systemctl >/dev/null 2>&1 && as_root systemctl enable --now docker
        return
    fi
    if command -v apk >/dev/null 2>&1; then
        as_root apk add docker
        command -v rc-update >/dev/null 2>&1 && as_root rc-update add docker default
        command -v service >/dev/null 2>&1 && as_root service docker start
        return
    fi

    TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/get-docker.XXXXXX")"
    curl -fsSL "$DOCKER_INSTALL_URL" -o "$TEMP_FILE"
    as_root sh "$TEMP_FILE"
    rm -f "$TEMP_FILE"
    TEMP_FILE=""
    command -v systemctl >/dev/null 2>&1 && as_root systemctl enable --now docker
}

install_docker() {
    case "$(uname -s)" in
        Darwin)
            command -v brew >/dev/null 2>&1 || die "Homebrew is required for automatic Docker Desktop installation; install Docker manually from https://docs.docker.com/desktop/setup/install/mac-install/"
            brew install --cask docker
            open -a Docker >/dev/null 2>&1 || true
            ;;
        Linux)
            install_docker_linux
            ;;
        MINGW* | MSYS* | CYGWIN*)
            command -v winget.exe >/dev/null 2>&1 || die "winget is required for automatic Docker Desktop installation; install Docker manually from https://docs.docker.com/desktop/setup/install/windows-install/"
            winget.exe install --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
            ;;
        *)
            die "automatic Docker installation is unsupported on $(uname -s); install Docker manually from https://docs.docker.com/get-docker/"
            ;;
    esac
    hash -r
}

wait_for_docker() {
    local attempts=0
    while [ "$attempts" -lt 30 ]; do
        docker info >/dev/null 2>&1 && return 0
        attempts=$((attempts + 1))
        sleep 2
    done
    return 1
}

command -v curl >/dev/null 2>&1 || die "curl is required to run this installer"

if ! command -v docker >/dev/null 2>&1; then
    if ! confirm_docker_install; then
        echo "Docker was not installed. Install it manually, then run this command again:" >&2
        echo "  https://docs.docker.com/get-docker/" >&2
        exit 1
    fi
    echo "Installing Docker..."
    install_docker
fi

command -v docker >/dev/null 2>&1 || die "Docker installation completed but the docker command is still unavailable; restart your shell and rerun this command"
if ! wait_for_docker; then
    die "Docker is installed but its daemon is not running; start Docker and rerun this command"
fi

mkdir -p "$INSTALL_DIR"
TEMP_FILE="$(mktemp "$INSTALL_DIR/.devtools.XXXXXX")"
echo "Installing devtools wrapper to $DEST..."
curl -fsSL "$WRAPPER_URL" -o "$TEMP_FILE"
chmod +x "$TEMP_FILE"
mv -f "$TEMP_FILE" "$DEST"
TEMP_FILE=""
echo "Installed devtools."

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "Warning: $INSTALL_DIR is not in your PATH."
    echo "Add this line to your shell profile:"
    echo ""
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
fi

echo ""
echo "Done. Run 'devtools --help' to get started."
