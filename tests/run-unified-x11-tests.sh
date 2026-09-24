#!/usr/bin/env bash
# Regression checks for the unified X11 backend; no real display changes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/x11-virtual.sh"
logi() { :; }; logd() { :; }; logw() { :; }; loge() { :; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
VIRTUAL_DISPLAY=:99
VIRTUAL_NAME_PREFIX=GHOST
VIRTUAL_MONITORS=2
VIRTUAL_RESOLUTION=1920x1080
VIRTUAL_SCALE=1
VIRTUAL_DPI=96
VIRTUAL_LAYOUT=horizontal
VIRTUAL_MAX_WIDTH=8192
VIRTUAL_MAX_HEIGHT=8192
VIRTUAL_MONITOR_SPECS=''
XORG_BIN=/usr/bin/Xorg
DUMMY_XORG_CONF="$TMP/xorg.conf"
DUMMY_PID_FILE="$TMP/xorg.pid"
XORG_LOG_DIR="$TMP"
expect_failure() { if "$@"; then echo "FAIL: expected failure: $*" >&2; exit 1; fi; }
build_monitor_specs
[[ $FRAMEBUFFER_WIDTH == 3840 && $FRAMEBUFFER_HEIGHT == 1080 && ${MONITOR_X[1]} == 1920 ]]
VIRTUAL_RESOLUTION=broken
expect_failure build_monitor_specs
VIRTUAL_RESOLUTION=1920x1080
VIRTUAL_MONITOR_SPECS='1280x720@1.5,1920x1080@1'
VIRTUAL_LAYOUT=vertical
build_monitor_specs
[[ $FRAMEBUFFER_WIDTH == 1920 && $FRAMEBUFFER_HEIGHT == 2160 && ${MONITOR_Y[1]} == 1080 ]]
for spec in 'broken' '100x100@0.0001' '100x100@99999999999999999999999999' '100x100,' '100x100,,200x200'; do
    VIRTUAL_MONITOR_SPECS=$spec
    expect_failure build_monitor_specs
done
VIRTUAL_MONITOR_SPECS=''
VIRTUAL_DPI=0
expect_failure build_monitor_specs
VIRTUAL_DPI=96
VIRTUAL_LAYOUT=diagonal
expect_failure build_monitor_specs
VIRTUAL_LAYOUT=horizontal
VIRTUAL_MAX_WIDTH=0
expect_failure build_monitor_specs
VIRTUAL_MAX_WIDTH=8192
VIRTUAL_MONITORS=99999999999999999999999999999
expect_failure build_monitor_specs
VIRTUAL_MONITORS=2
build_monitor_specs
# Mock xrandr records arguments and injects failures at each stage.
xrandr() {
    printf '%s\n' "$*" >> "$TMP/calls"
    [[ "${FAIL_STAGE:-}" != "$1" ]] || return 1
    if [[ $1 == --listmonitors ]]; then
        printf 'Monitors: 2\n 0: +*GHOST-1 1920/508x1080/286+0+0 none\n 1: +OTHER-1 100/26x100/26+0+0 none\n'
    fi
}
xrdb() { cat >/dev/null; [[ "${FAIL_STAGE:-}" != xrdb ]]; }
virtual_configure_monitors
grep -q -- '--delmonitor GHOST-1' "$TMP/calls"
if grep -q -- '--delmonitor OTHER-1' "$TMP/calls"; then exit 1; fi
for FAIL_STAGE in --fb --listmonitors --delmonitor --setmonitor xrdb; do
    expect_failure virtual_configure_monitors
done
unset FAIL_STAGE
# A stale PID that points at this shell must never count as our Xorg.
printf '%s\n' "$$" > "$DUMMY_PID_FILE"
expect_failure virtual_is_xorg_running
virtual_stop_xorg
[[ ! -e $DUMMY_PID_FILE ]]
# Existing managed Xorg avoids any launch; unmanaged responding displays fail.
virtual_is_xorg_running() { return 0; }
virtual_start_xorg
virtual_is_xorg_running() { return 1; }
xset() { return 0; }
expect_failure virtual_start_xorg
# Launch arguments include -noreset; launch is mocked using a shell function.
xset() { return 1; }
touch "$DUMMY_XORG_CONF"
mock_xorg() { printf '%s\n' "$*" > "$TMP/launch"; }
XORG_BIN=mock_xorg
virtual_start_xorg
wait "$(cat "$DUMMY_PID_FILE")"
grep -q -- '-noreset -nolisten tcp' "$TMP/launch"
echo 'PASS: unified X11 geometry, failure propagation, monitor filtering and lifecycle checks'
