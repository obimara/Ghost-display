#!/usr/bin/env bash
set -u

GHOST_DISPLAY="${GHOST_DISPLAY:-:20}"
GHOST_XORG_CONFIG="${GHOST_XORG_CONFIG:-/etc/X11/ghost-display.conf}"
RUSTDESK_DRM_DIR="${RUSTDESK_DRM_DIR:-/sys/class/drm}"

section() {
    printf '\n== %s ==\n' "$1"
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'ok: %s -> %s\n' "$1" "$(command -v "$1")"
    else
        printf 'missing: %s\n' "$1"
    fi
}

section "Commands"
for cmd in Xorg xrandr xset xrdb ghost-display-x11 rustdesk-auto-display rustdesk systemctl; do
    check_command "${cmd}"
done

section "Files"
for file in "${GHOST_XORG_CONFIG}" /usr/local/bin/ghost-display-x11 /usr/local/bin/rustdesk-auto-display /etc/systemd/system/ghost-display-x11.service; do
    if [[ -e "${file}" ]]; then
        printf 'ok: %s\n' "${file}"
    else
        printf 'missing: %s\n' "${file}"
    fi
done

section "DRM connectors"
shopt -s nullglob
statuses=("${RUSTDESK_DRM_DIR}"/card*-*/status)
if [[ ${#statuses[@]} -eq 0 ]]; then
    printf 'no DRM connector status files in %s\n' "${RUSTDESK_DRM_DIR}"
else
    for status in "${statuses[@]}"; do
        printf '%s: %s\n' "${status}" "$(cat "${status}" 2>/dev/null || printf 'unreadable')"
    done
fi

section "Ghost dry-run"
if command -v ghost-display-x11 >/dev/null 2>&1; then
    ghost-display-x11 --dry-run || true
elif [[ -x ./scripts/ghost-display-x11.sh ]]; then
    ./scripts/ghost-display-x11.sh --dry-run || true
else
    printf 'ghost-display-x11 not available\n'
fi

section "RustDesk display choice"
if command -v rustdesk-auto-display >/dev/null 2>&1; then
    rustdesk-auto-display --print || true
elif [[ -x ./scripts/rustdesk-auto-display.sh ]]; then
    ./scripts/rustdesk-auto-display.sh --print || true
else
    printf 'rustdesk-auto-display not available\n'
fi

section "X11 monitor state"
if command -v xrandr >/dev/null 2>&1; then
    DISPLAY="${GHOST_DISPLAY}" xrandr --listmonitors 2>/dev/null || printf 'cannot query %s\n' "${GHOST_DISPLAY}"
else
    printf 'xrandr not available\n'
fi

section "systemd"
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl --no-pager status ghost-display-x11.service || true
else
    printf 'systemd is not active in this environment\n'
fi
