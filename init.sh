#!/usr/bin/env bash
# Bootstrap a new project with devtools: ensures Docker + Just + the devtools
# wrapper are present, pulls the public image, and runs `devtools init`.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/sphyrix/devtools-install/main/init.sh | bash
#
# The devtools source repo is private; this uses the public container image
# (ghcr.io/sphyrix/devtools), so no GitHub authentication is needed.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: bash 4+ required (current: $BASH_VERSION). On macOS, install via: brew install bash" >&2
    exit 1
fi

# Public bootstrap repo that hosts the wrapper. Override to test a branch/fork.
DEVTOOLS_RAW_BASE="${DEVTOOLS_RAW_BASE:-https://raw.githubusercontent.com/sphyrix/devtools-install/main}"

# Public image (repo source stays private; the image package is public).
DEVTOOLS_IMAGE="${DEVTOOLS_IMAGE:-ghcr.io/sphyrix/devtools:latest}"

echo "=== Devtools Bootstrap ==="

# Check/install Docker
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing..."
    if command -v apt-get &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm docker
        sudo systemctl enable --now docker
    elif command -v brew &> /dev/null; then
        brew install --cask docker
    else
        echo "Error: Could not auto-install Docker. Please install it manually." >&2
        exit 1
    fi
fi

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker is installed but not running. Start Docker and try again." >&2
    exit 1
fi

# Check/install Just
if ! command -v just &> /dev/null; then
    echo "Just not found. Installing..."
    if command -v cargo &> /dev/null; then
        cargo install just
    elif command -v brew &> /dev/null; then
        brew install just
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm just
    else
        # Fallback: install from prebuilt binary
        curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
    fi
fi

# Check/install devtools host wrapper
if ! command -v devtools &> /dev/null; then
    echo "devtools wrapper not found. Installing..."
    INSTALL_DIR="${DEVTOOLS_INSTALL_DIR:-$HOME/.local/bin}"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$DEVTOOLS_RAW_BASE/devtools.sh" -o "$INSTALL_DIR/devtools"
    chmod +x "$INSTALL_DIR/devtools"
    export PATH="$INSTALL_DIR:$PATH"
    echo "Installed devtools wrapper to $INSTALL_DIR/devtools."
    if [[ ":${PATH_BEFORE_EXPORT:-$PATH}:" != *":$INSTALL_DIR:"* ]]; then
        echo "Add the following to your shell profile to persist:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

echo "Pulling devtools image..."
docker pull "$DEVTOOLS_IMAGE"

echo "Initializing project..."

# Start with any flags already passed to init.sh, then append only missing ones.
# The image ENTRYPOINT is ["devtools"] so "init [flags]" works without --entrypoint.
ARGS=("$@")

# --- Project name ---
if [[ ! " $* " =~ " --name " ]]; then
    PROJECT_NAME=""
    while [[ -z "$PROJECT_NAME" ]]; do
        read -r -p "Project name: " PROJECT_NAME </dev/tty
        if [[ -z "$PROJECT_NAME" ]]; then
            echo "Project name cannot be empty." >&2
        fi
    done
    ARGS+=(--name "$PROJECT_NAME")
fi

# --- Organisation ---
if [[ ! " $* " =~ " --org " ]]; then
    ORG=""
    while [[ -z "$ORG" ]]; do
        read -r -p "Organisation/user (e.g., acme): " ORG </dev/tty
        if [[ -z "$ORG" ]]; then
            echo "Organisation cannot be empty." >&2
        fi
    done
    ARGS+=(--org "$ORG")
fi

# --- Language ---
if [[ ! " $* " =~ " --lang " ]]; then
    echo "Fetching available languages..."
    mapfile -t LANGS < <(docker run --rm "$DEVTOOLS_IMAGE" list-langs)

    echo "Available languages:"
    echo "  0. none"
    for i in "${!LANGS[@]}"; do
        echo "  $((i+1)). ${LANGS[$i]}"
    done

    read -r -p "Select languages (comma-separated numbers, or 0 for none): " LANG_SEL </dev/tty
    if [[ "$LANG_SEL" != "0" && -n "$LANG_SEL" ]]; then
        IFS=',' read -ra LANG_IDXS <<< "$LANG_SEL"
        for LANG_IDX in "${LANG_IDXS[@]}"; do
            LANG_IDX="${LANG_IDX// /}"  # trim spaces
            if [[ "$LANG_IDX" =~ ^[0-9]+$ ]] && (( LANG_IDX >= 1 && LANG_IDX <= ${#LANGS[@]} )); then
                ARGS+=(--lang "${LANGS[$((LANG_IDX-1))]}")
            else
                echo "Warning: ignoring invalid lang selection '$LANG_IDX'." >&2
            fi
        done
    fi
fi

# --- Addons ---
if [[ ! " $* " =~ " --addons " ]]; then
    echo "Fetching available addons..."
    mapfile -t ADDONS < <(docker run --rm "$DEVTOOLS_IMAGE" list-addons)
    if [[ ${#ADDONS[@]} -gt 0 ]]; then
        echo "Available addons:"
        for i in "${!ADDONS[@]}"; do
            echo "  $((i+1)). ${ADDONS[$i]}"
        done

        read -r -p "Select addons (comma-separated numbers, or enter for none): " ADDON_SEL </dev/tty
        SELECTED_ADDONS=()
        if [[ -n "$ADDON_SEL" ]]; then
            IFS=',' read -ra TOKENS <<< "$ADDON_SEL"
            for token in "${TOKENS[@]}"; do
                token="${token// /}"
                if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#ADDONS[@]} )); then
                    SELECTED_ADDONS+=("${ADDONS[$((token-1))]}")
                else
                    echo "Warning: ignoring invalid addon selection '$token'." >&2
                fi
            done
        fi

        if [[ ${#SELECTED_ADDONS[@]} -gt 0 ]]; then
            OLD_IFS="$IFS"
            IFS=','
            ADDON_STR="${SELECTED_ADDONS[*]}"
            IFS="$OLD_IFS"
            ARGS+=(--addons "$ADDON_STR")
        fi
    fi
fi

docker run --rm -v "$(pwd):/project" "$DEVTOOLS_IMAGE" init "${ARGS[@]}"

echo ""
echo "Done! Commit the generated files:"
echo "  git add Justfile .project.toml .gitignore"
echo "  git commit -m 'chore: initialize devtools'"
