#!/usr/bin/env bash
# Install the devtools host wrapper to ~/.local/bin/devtools.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/sphyrix/devtools-install/main/install.sh | bash
#
# The devtools source repo is private; the wrapper this installs runs the public
# container image (ghcr.io/sphyrix/devtools), so no GitHub authentication is needed.
set -euo pipefail

# Public bootstrap repo that hosts the wrapper. Override to test a branch/fork.
DEVTOOLS_RAW_BASE="${DEVTOOLS_RAW_BASE:-https://raw.githubusercontent.com/sphyrix/devtools-install/main}"
WRAPPER_URL="$DEVTOOLS_RAW_BASE/devtools.sh"

INSTALL_DIR="${DEVTOOLS_INSTALL_DIR:-$HOME/.local/bin}"
DEST="$INSTALL_DIR/devtools"

if ! command -v curl > /dev/null 2>&1; then
    echo "Error: curl is required but not found." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
echo "Installing devtools wrapper to $DEST..."
curl -fsSL "$WRAPPER_URL" -o "$DEST"
chmod +x "$DEST"
echo "Installed."

if ! command -v docker > /dev/null 2>&1; then
    echo ""
    echo "Note: docker was not found. devtools runs inside a container, so install Docker"
    echo "      before using it: https://docs.docker.com/get-docker/"
fi

# Warn if INSTALL_DIR is not in PATH.
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "Warning: $INSTALL_DIR is not in your PATH."
    echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "Done. Run 'devtools --help' to get started (Docker required)."
