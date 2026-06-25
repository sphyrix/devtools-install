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
(`devtools.sh`) that runs:

```bash
docker run --rm -it -v "$(pwd):/project" -w /project ghcr.io/sphyrix/devtools:latest "$@"
```

This keeps the source private while distribution flows entirely through the public
container image.

## Requirements

- **Docker** — the toolkit runs inside a container. `init.sh` will attempt to
  install it (apt/pacman/brew); `install.sh` only warns if it is missing.
- **bash 4+** for `init.sh` (macOS ships bash 3; `brew install bash`).

## Configuration

Environment variables honoured by the scripts and wrapper:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEVTOOLS_IMAGE` | `ghcr.io/sphyrix/devtools:latest` | Override the container image. |
| `DEVTOOLS_VERSION` | `v0.3.6` | Image version the wrapper expects (re-pulls on mismatch). |
| `DEVTOOLS_INSTALL_DIR` | `$HOME/.local/bin` | Where the wrapper is installed. |
| `DEVTOOLS_RAW_BASE` | `https://raw.githubusercontent.com/sphyrix/devtools-install/main` | Base URL for the wrapper download (test branches/forks). |

A project's `.project.toml` may set an `image = "..."` line, which the wrapper
prefers over the default.
