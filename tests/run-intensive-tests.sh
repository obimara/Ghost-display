#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

scripts=(
    install.sh
    scripts/ghost-display-x11.sh
    scripts/compare-ghost-profiles.sh
    scripts/debug-ghost-display.sh
    scripts/rustdesk-auto-display.sh
    tests/run-ghost-display-tests.sh
    tests/run-intensive-tests.sh
)

printf '== bash syntax ==\n'
bash -n "${scripts[@]}"

printf '== local harness ==\n'
tests/run-ghost-display-tests.sh

printf '== profile comparison ==\n'
scripts/compare-ghost-profiles.sh >/tmp/ghost-display-profile-compare.out
cat /tmp/ghost-display-profile-compare.out

printf '== direct Wayland selector check ==\n'
fake_drm="$(mktemp -d)"
fake_runtime="$(mktemp -d)"
fake_socket_pid=""
trap '[[ -n "${fake_socket_pid}" ]] && kill "${fake_socket_pid}" >/dev/null 2>&1 || true; rm -rf "${fake_drm}" "${fake_runtime}" /tmp/ghost-display-profile-compare.out' EXIT
mkdir -p "${fake_drm}/card0-HDMI-A-1"
echo connected >"${fake_drm}/card0-HDMI-A-1/status"
python3 - "${fake_runtime}/wayland-1" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.listen(1)
while True:
    time.sleep(1)
PY
fake_socket_pid="$!"
for _ in {1..50}; do
    [[ -S "${fake_runtime}/wayland-1" ]] && break
    sleep 0.02
done
choice="$(WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland XDG_RUNTIME_DIR="${fake_runtime}" RUSTDESK_DRM_DIR="${fake_drm}" scripts/rustdesk-auto-display.sh --print)"
if [[ "${choice}" != "wayland:wayland-1" ]]; then
    echo "Expected wayland:wayland-1, got ${choice}" >&2
    exit 1
fi
printf '%s\n' "${choice}"

printf '== whitespace check ==\n'
git diff --check

if command -v shellcheck >/dev/null 2>&1; then
    printf '== shellcheck ==\n'
    shellcheck "${scripts[@]}"
else
    printf '== shellcheck skipped: command not found ==\n'
fi

printf 'Intensive ghost-display checks passed.\n'
