#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/devtools-install-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
PASS=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_case() {
    local name="$1" root
    root="$WORKDIR/$name"
    mkdir -p "$root/bin" "$root/home" "$root/install"
    for tool in bash sh env rm mkdir mktemp chmod mv cp grep cat touch; do
        ln -s "$(command -v "$tool")" "$root/bin/$tool"
    done
    printf '#!/usr/bin/env bash\necho wrapper-fixture\n' > "$root/wrapper-fixture"
    chmod +x "$root/wrapper-fixture"

    cat > "$root/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-Linux}"
EOF
    cat > "$root/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
    cat > "$root/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[ -n "$dest" ] || { echo "curl stub needs -o" >&2; exit 90; }
case "$url" in
    */devtools.sh) cp "$WRAPPER_FIXTURE" "$dest" ;;
    *) cp "$DOCKER_INSTALL_FIXTURE" "$dest" ;;
esac
EOF
    chmod +x "$root/bin/curl" "$root/bin/id" "$root/bin/sleep" "$root/bin/systemctl" "$root/bin/uname"
    printf '%s\n' "$root"
}

write_docker_stub() {
    local root="$1" info_status="${2:-0}"
    cat > "$root/bin/docker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = info ]; then exit $info_status; fi
exit 0
EOF
    chmod +x "$root/bin/docker"
}

write_docker_installer() {
    local root="$1"
    cat > "$root/docker-installer" <<EOF
#!/bin/sh
cat > '$root/bin/docker' <<'DOCKER'
#!/usr/bin/env bash
[ "\${1:-}" = info ] && exit 0
exit 0
DOCKER
chmod +x '$root/bin/docker'
touch '$root/docker-installed'
EOF
}

run_installer() {
    local root="$1" policy="$2"
    shift 2
    env \
        PATH="$root/bin" \
        HOME="$root/home" \
        DEVTOOLS_INSTALL_DIR="$root/install" \
        DEVTOOLS_INSTALL_DOCKER="$policy" \
        DEVTOOLS_RAW_BASE="https://fixture.invalid" \
        DEVTOOLS_DOCKER_INSTALL_URL="https://fixture.invalid/get-docker.sh" \
        WRAPPER_FIXTURE="$root/wrapper-fixture" \
        DOCKER_INSTALL_FIXTURE="$root/docker-installer" \
        "$@" \
        bash "$REPO_ROOT/install.sh"
}

case_installed() {
    local root output
    root="$(make_case installed)"
    write_docker_stub "$root"
    output="$(run_installer "$root" no 2>&1)" || fail "installed Docker path failed: $output"
    cmp -s "$root/wrapper-fixture" "$root/install/devtools" || fail "wrapper was not installed"
    [ -x "$root/install/devtools" ] || fail "installed wrapper is not executable"
    [[ "$output" == *"Installed devtools."* ]] || fail "success output missing"
    PASS=$((PASS + 1))
}

case_declined() {
    local root output rc
    root="$(make_case declined)"
    write_docker_installer "$root"
    set +e
    output="$(run_installer "$root" no 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "declined install exited $rc"
    [ ! -e "$root/install/devtools" ] || fail "DX installed after Docker was declined"
    [ ! -e "$root/docker-installed" ] || fail "Docker installed after it was declined"
    [[ "$output" == *"Docker was not installed"* ]] || fail "decline guidance missing"
    PASS=$((PASS + 1))
}

case_accepted() {
    local root output
    root="$(make_case accepted)"
    write_docker_installer "$root"
    output="$(run_installer "$root" yes 2>&1)" || fail "accepted install failed: $output"
    [ -e "$root/docker-installed" ] || fail "Docker installer was not run"
    [ -x "$root/install/devtools" ] || fail "DX wrapper was not installed after Docker"
    PASS=$((PASS + 1))
}

case_noninteractive() {
    local root output rc
    root="$(make_case noninteractive)"
    write_docker_installer "$root"
    set +e
    output="$(run_installer "$root" ask 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "non-interactive prompt exited $rc"
    [[ "$output" == *"no interactive terminal is available"* ]] || fail "non-interactive guidance missing"
    [ ! -e "$root/install/devtools" ] || fail "DX installed without dependency consent"
    PASS=$((PASS + 1))
}

case_daemon_stopped() {
    local root output rc
    root="$(make_case daemon-stopped)"
    write_docker_stub "$root" 1
    set +e
    output="$(run_installer "$root" no 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "stopped daemon exited $rc"
    [[ "$output" == *"daemon is not running"* ]] || fail "stopped-daemon guidance missing"
    [ ! -e "$root/install/devtools" ] || fail "DX installed with an unusable Docker daemon"
    PASS=$((PASS + 1))
}

case_installed
case_declined
case_accepted
case_noninteractive
case_daemon_stopped
printf 'PASS: %d installer scenarios\n' "$PASS"
