# devtools-install

Public bootstrap installer for **devtools** — Sphyrix's containerized developer toolkit.

The devtools source lives in a **private** repo, but the install scripts and the
container image are **public**, so anyone can install and run it without GitHub
credentials.

## Install

Install the `devtools` host wrapper to `~/.local/bin/devtools`:

```bash
curl -fsSL https://raw.githubusercontent.com/sphyrix/devtools-install/main/install.sh | bash
```

Then run:

```bash
devtools --help
```

## Bootstrap a new project

To set up Docker + Just + the wrapper and scaffold a project interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/sphyrix/devtools-install/main/init.sh | bash
```

You can pass flags through to `devtools init` to skip the prompts, e.g.:

```bash
curl -fsSL https://raw.githubusercontent.com/sphyrix/devtools-install/main/init.sh | bash -s -- \
  --name myapp --org acme --lang golang
```

## How it works

devtools is a **containerized** toolkit: the binary ships with bundled `just`
recipes inside its image and is designed to run in-container. The installer
therefore does **not** extract a bare binary — instead it installs a small wrapper
(`devtools.sh`) that runs (TTY flags only when a terminal is attached, so CI and
scripts work too):

```bash
docker run --rm [-it] [--env-file .env] -v "$(pwd):/project" -w /project ghcr.io/sphyrix/devtools:vX.Y.Z "$@"
```

This keeps the source private while distribution flows entirely through the public
container image.

**Version pinning (release rule):** `devtools.sh` here is a byte-identical mirror of
`scripts/devtools.sh` in the devtools repo, and pins `DEFAULT_IMAGE` to the current
release tag. Every devtools release bumps that pin and syncs this mirror in the same
change — a stale pin here is a release-process bug. Pinned tags are immutable, so
the wrapper pulls only when the image is absent and works offline once cached.

**Secrets:** recipes read environment variables only. Hand them over with a
gitignored `.env` in the project root (picked up automatically) or
`DEVTOOLS_ENV_FILE=path/to/file` — the same contract CI uses, so anything CI does
is reproducible locally given the right env.

## Requirements

- **Docker** — the toolkit runs inside a container. `init.sh` will attempt to
  install it (apt/pacman/brew); `install.sh` only warns if it is missing.
- **bash 4+** for `init.sh` (macOS ships bash 3; `brew install bash`).

## Configuration

Environment variables honoured by the scripts and wrapper:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEVTOOLS_IMAGE` | (the pinned release tag) | Override the container image — strongest override. |
| `DEVTOOLS_ENV_FILE` | `.env` if present | KEY=VALUE file passed into the container as env (the secrets interface). |
| `DEVTOOLS_INSTALL_DIR` | `$HOME/.local/bin` | Where the wrapper is installed. |
| `DEVTOOLS_RAW_BASE` | `https://raw.githubusercontent.com/sphyrix/devtools-install/main` | Base URL for the wrapper download (test branches/forks). |

Image resolution order: `DEVTOOLS_IMAGE` env → `.project.toml` `[devtools] image`
→ the wrapper's pinned release tag. (`DEVTOOLS_VERSION` label-checking is gone —
the pin in the image tag replaced it.)
