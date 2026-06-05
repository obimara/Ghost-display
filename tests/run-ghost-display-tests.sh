#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/ghost-display-x11.sh"
CONFIG="${ROOT_DIR}/config/20-ghost-display.conf"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="${TMP_DIR}/bin"
LOG_FILE="${TMP_DIR}/commands.log"
mkdir -p "${MOCK_BIN}"
: >"${LOG_FILE}"

cleanup() {
    if [[ -f "${TMP_DIR}/ghost-display-20.pid" ]]; then
        kill "$(cat "${TMP_DIR}/ghost-display-20.pid")" >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

write_mock_commands() {
    cat >"${MOCK_BIN}/Xorg" <<'MOCK'
#!/usr/bin/env bash
printf 'Xorg %s\n' "$*" >>"${GHOST_TEST_LOG}"
while true; do sleep 1; done
MOCK

    cat >"${MOCK_BIN}/xset" <<'MOCK'
#!/usr/bin/env bash
printf 'xset %s DISPLAY=%s\n' "$*" "${DISPLAY:-}" >>"${GHOST_TEST_LOG}"
exit 0
MOCK

    cat >"${MOCK_BIN}/xrandr" <<'MOCK'
#!/usr/bin/env bash
printf 'xrandr %s DISPLAY=%s\n' "$*" "${DISPLAY:-}" >>"${GHOST_TEST_LOG}"
if [[ "${1:-}" == "--listmonitors" ]]; then
    cat <<'MONITORS'
Monitors: 3
 0: +Ghost-1 1920/508x1080/286+0+0 none
 1: +Ghost-2 1920/508x1080/286+1920+0 none
 2: +HDMI-A-1 1920/508x1080/286+0+0 HDMI-A-1
MONITORS
fi
exit 0
MOCK

    cat >"${MOCK_BIN}/xrdb" <<'MOCK'
#!/usr/bin/env bash
payload="$(cat)"
printf 'xrdb %s DISPLAY=%s payload=%s\n' "$*" "${DISPLAY:-}" "${payload}" >>"${GHOST_TEST_LOG}"
exit 0
MOCK

    chmod +x "${MOCK_BIN}/Xorg" "${MOCK_BIN}/xset" "${MOCK_BIN}/xrandr" "${MOCK_BIN}/xrdb"
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    if ! grep -Fq -- "${pattern}" "${file}"; then
        echo "Expected to find '${pattern}' in ${file}" >&2
        echo "--- ${file} ---" >&2
        cat "${file}" >&2
        exit 1
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    if grep -Fq -- "${pattern}" "${file}"; then
        echo "Did not expect to find '${pattern}' in ${file}" >&2
        echo "--- ${file} ---" >&2
        cat "${file}" >&2
        exit 1
    fi
}

run_dry_profile() {
    local name="$1"
    shift
    local out="${TMP_DIR}/${name}.out"
    env "$@" "${SCRIPT}" --dry-run >"${out}"
    echo "${out}"
}

write_mock_commands

# 1. Default dual 1080p profile.
default_out="$(run_dry_profile default)"
assert_contains "${default_out}" "framebuffer=3840x1080"
assert_contains "${default_out}" "log="
if [[ "${EUID}" -eq 0 ]]; then
    assert_contains "${default_out}" "log=/var/log/ghost-display-20.log"
else
    assert_contains "${default_out}" "log=/tmp/ghost-display-20.log"
fi
assert_contains "${default_out}" "Ghost-1: 1920x1080+0+0"
assert_contains "${default_out}" "Ghost-2: 1920x1080+1920+0"

custom_display_out="$(run_dry_profile custom-display GHOST_DISPLAY=:21)"
assert_contains "${custom_display_out}" "DISPLAY=:21"
if [[ "${EUID}" -eq 0 ]]; then
    assert_contains "${custom_display_out}" "log=/var/log/ghost-display-21.log"
else
    assert_contains "${custom_display_out}" "log=/tmp/ghost-display-21.log"
fi

# 2. Scaled dual profile.
scaled_out="$(run_dry_profile scaled GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 GHOST_SCALE=1.25)"
assert_contains "${scaled_out}" "framebuffer=4800x1350"
assert_contains "${scaled_out}" "Ghost-1: 2400x1350+0+0"
assert_contains "${scaled_out}" "Ghost-2: 2400x1350+2400+0"

# 3. Mixed per-monitor profile.
mixed_out="$(run_dry_profile mixed GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25 GHOST_DPI=110)"
assert_contains "${mixed_out}" "framebuffer=5120x1800"
assert_contains "${mixed_out}" "Ghost-1: 1920x1080+0+0 (443x249mm)"
assert_contains "${mixed_out}" "Ghost-2: 3200x1800+1920+0 (739x416mm)"

# 4. Vertical triple profile.
vertical_out="$(run_dry_profile vertical GHOST_MONITORS=3 GHOST_RESOLUTION=1280x720 GHOST_LAYOUT=vertical)"
assert_contains "${vertical_out}" "framebuffer=1280x2160"
assert_contains "${vertical_out}" "Ghost-3: 1280x720+0+1440"

# 5. Custom prefix, custom log, whitespace-tolerant monitor specs.
custom_out="$(run_dry_profile custom GHOST_NAME_PREFIX=Desk GHOST_XORG_LOG=/tmp/custom-xorg.log GHOST_MONITOR_SPECS=' 1024x768@1 , 800x600@1.5 ' GHOST_DPI=100)"
assert_contains "${custom_out}" "log=/tmp/custom-xorg.log"
assert_contains "${custom_out}" "framebuffer=2224x900"
assert_contains "${custom_out}" "Desk-1: 1024x768+0+0"
assert_contains "${custom_out}" "Desk-2: 1200x900+1024+0"

# Invalid input checks.
if GHOST_RESOLUTION=1920-1080 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-resolution.out" 2>"${TMP_DIR}/bad-resolution.err"; then
    echo "Expected invalid resolution to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-resolution.err" "Invalid resolution"

if GHOST_SCALE=0 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-scale.out" 2>"${TMP_DIR}/bad-scale.err"; then
    echo "Expected invalid scale to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-scale.err" "GHOST_SCALE must be a positive number"

if GHOST_LAYOUT=diagonal "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-layout.out" 2>"${TMP_DIR}/bad-layout.err"; then
    echo "Expected invalid layout to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-layout.err" "GHOST_LAYOUT must be 'horizontal' or 'vertical'"

if GHOST_DPI=0 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-dpi.out" 2>"${TMP_DIR}/bad-dpi.err"; then
    echo "Expected invalid DPI to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-dpi.err" "GHOST_DPI must be a positive number"

if GHOST_MONITOR_SPECS=1920x1080@bad "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-spec-scale.out" 2>"${TMP_DIR}/bad-spec-scale.err"; then
    echo "Expected invalid per-monitor scale to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-spec-scale.err" "Invalid scale 'bad'"

if GHOST_MONITORS=0 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-monitors.out" 2>"${TMP_DIR}/bad-monitors.err"; then
    echo "Expected invalid monitor count to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-monitors.err" "GHOST_MONITORS must be a positive integer"

if GHOST_MAX_WIDTH=3000 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-max.out" 2>"${TMP_DIR}/bad-max.err"; then
    echo "Expected framebuffer width guard to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-max.err" "exceeds 3000x8192"

if GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 GHOST_LAYOUT=vertical GHOST_MAX_HEIGHT=2000 "${SCRIPT}" --dry-run >"${TMP_DIR}/bad-max-height.out" 2>"${TMP_DIR}/bad-max-height.err"; then
    echo "Expected framebuffer height guard to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/bad-max-height.err" "exceeds 8192x2000"

# Validate framebuffer guard.
if GHOST_MONITORS=3 GHOST_RESOLUTION=3840x2160 "${SCRIPT}" --dry-run >"${TMP_DIR}/too-large.out" 2>"${TMP_DIR}/too-large.err"; then
    echo "Expected oversized framebuffer profile to fail" >&2
    exit 1
fi
assert_contains "${TMP_DIR}/too-large.err" "exceeds 8192x8192"

# Exercise runtime path with mocked Xorg/XRandR/Xrdb tools.
echo 999999 >"${TMP_DIR}/ghost-display-20.pid"
PATH="${MOCK_BIN}:${PATH}" \
GHOST_TEST_LOG="${LOG_FILE}" \
XDG_RUNTIME_DIR="${TMP_DIR}" \
GHOST_XORG_CONFIG="${CONFIG}" \
GHOST_XORG_LOG="${TMP_DIR}/xorg.log" \
GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25 \
GHOST_DPI=110 \
"${SCRIPT}" >"${TMP_DIR}/runtime.out"

assert_contains "${TMP_DIR}/runtime.out" "framebuffer=5120x1800"
assert_contains "${LOG_FILE}" "Xorg :20 -config ${CONFIG} -noreset +extension RANDR -logfile ${TMP_DIR}/xorg.log"
assert_not_contains "${TMP_DIR}/ghost-display-20.pid" "999999"
assert_contains "${LOG_FILE}" "xrandr --fb 5120x1800 DISPLAY=:20"
assert_contains "${LOG_FILE}" "xrandr --delmonitor Ghost-1 DISPLAY=:20"
assert_contains "${LOG_FILE}" "xrandr --delmonitor Ghost-2 DISPLAY=:20"
assert_not_contains "${LOG_FILE}" "xrandr --delmonitor HDMI-A-1 DISPLAY=:20"
assert_contains "${LOG_FILE}" "xrandr --setmonitor Ghost-1 1920/443x1080/249+0+0 none DISPLAY=:20"
assert_contains "${LOG_FILE}" "xrandr --setmonitor Ghost-2 3200/739x1800/416+1920+0 none DISPLAY=:20"
assert_contains "${LOG_FILE}" "xrdb -merge DISPLAY=:20 payload=Xft.dpi: 110"

# Compare all four profiles and verify the discrepancy summary.
compare_out="${TMP_DIR}/compare.out"
"${ROOT_DIR}/scripts/compare-ghost-profiles.sh" >"${compare_out}"
assert_contains "${compare_out}" "balanced-dual    3840x1080"
assert_contains "${compare_out}" "scaled-dual      4800x1350"
assert_contains "${compare_out}" "mixed-workspace  4480x1440"
assert_contains "${compare_out}" "vertical-triple  1280x2160"
assert_contains "${compare_out}" "+8.9"
assert_contains "${compare_out}" "Use balanced-dual as the finished profile"
"${SCRIPT}" --help >"${TMP_DIR}/help.out"
assert_contains "${TMP_DIR}/help.out" "GHOST_XORG_LOG"
assert_contains "${ROOT_DIR}/systemd/ghost-display-x11.service" "Type=simple"
assert_contains "${ROOT_DIR}/systemd/ghost-display-x11.service" "GHOST_STAY_FOREGROUND=1"

# Auto-select RustDesk display from DRM connector status.
fake_drm="${TMP_DIR}/drm"
mkdir -p "${fake_drm}/card0-HDMI-A-1" "${fake_drm}/card0-DP-1"
echo disconnected >"${fake_drm}/card0-HDMI-A-1/status"
echo disconnected >"${fake_drm}/card0-DP-1/status"
mkdir -p "${fake_drm}/card0-Writeback-1"
echo connected >"${fake_drm}/card0-Writeback-1/status"
RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-none.out"
assert_contains "${TMP_DIR}/auto-none.out" ":20"
echo connected >"${fake_drm}/card0-HDMI-A-1/status"
PATH="${MOCK_BIN}:${PATH}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-physical.out"
assert_contains "${TMP_DIR}/auto-physical.out" ":0"
WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-wayland.out"
assert_contains "${TMP_DIR}/auto-wayland.out" "wayland:wayland-1"
RUSTDESK_PREFER_WAYLAND=0 WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland PATH="${MOCK_BIN}:${PATH}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-wayland-disabled.out"
assert_contains "${TMP_DIR}/auto-wayland-disabled.out" ":0"

WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=x11 PATH="${MOCK_BIN}:${PATH}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-wayland-x11-session.out"
assert_contains "${TMP_DIR}/auto-wayland-x11-session.out" ":0"
echo disconnected >"${fake_drm}/card0-HDMI-A-1/status"
WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-wayland-no-connector.out"
assert_contains "${TMP_DIR}/auto-wayland-no-connector.out" ":20"
echo connected >"${fake_drm}/card0-HDMI-A-1/status"
PATH="${MOCK_BIN}:${PATH}" RUSTDESK_DRM_DIR="${fake_drm}" RUSTDESK_PHYSICAL_DISPLAY=:1 RUSTDESK_GHOST_DISPLAY=:21 "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-override.out"
assert_contains "${TMP_DIR}/auto-override.out" ":1"
PATH="/usr/bin:/bin" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-no-xset.out"
assert_contains "${TMP_DIR}/auto-no-xset.out" ":20"
RUSTDESK_SKIP_X_CHECK=1 RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" --print >"${TMP_DIR}/auto-skip-x-check.out"
assert_contains "${TMP_DIR}/auto-skip-x-check.out" ":0"
cat >"${MOCK_BIN}/mock-rustdesk" <<'MOCK'
#!/usr/bin/env bash
printf 'mock-rustdesk DISPLAY=%s WAYLAND_DISPLAY=%s\n' "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" >"${GHOST_TEST_LOG}.rustdesk"
MOCK
chmod +x "${MOCK_BIN}/mock-rustdesk"
PATH="${MOCK_BIN}:${PATH}" GHOST_TEST_LOG="${LOG_FILE}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" mock-rustdesk
assert_contains "${LOG_FILE}.rustdesk" "DISPLAY=:0"
WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland PATH="${MOCK_BIN}:${PATH}" GHOST_TEST_LOG="${LOG_FILE}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" mock-rustdesk
assert_contains "${LOG_FILE}.rustdesk" "WAYLAND_DISPLAY=wayland-1"
echo disconnected >"${fake_drm}/card0-HDMI-A-1/status"
PATH="${MOCK_BIN}:${PATH}" GHOST_TEST_LOG="${LOG_FILE}" RUSTDESK_DRM_DIR="${fake_drm}" "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" mock-rustdesk
assert_contains "${LOG_FILE}.rustdesk" "DISPLAY=:20"

"${ROOT_DIR}/scripts/debug-ghost-display.sh" >"${TMP_DIR}/debug.out"
assert_contains "${TMP_DIR}/debug.out" "== Commands =="
assert_contains "${TMP_DIR}/debug.out" "== RustDesk display choice =="

printf 'All ghost-display tests passed.\n'
