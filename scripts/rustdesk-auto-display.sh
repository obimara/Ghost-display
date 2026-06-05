#!/usr/bin/env bash
set -euo pipefail

PHYSICAL_DISPLAY="${RUSTDESK_PHYSICAL_DISPLAY:-:0}"
GHOST_DISPLAY="${RUSTDESK_GHOST_DISPLAY:-:20}"
DRM_DIR="${RUSTDESK_DRM_DIR:-/sys/class/drm}"
SKIP_X_CHECK="${RUSTDESK_SKIP_X_CHECK:-0}"

physical_connector_connected() {
    local status connector state
    shopt -s nullglob
    for status in "${DRM_DIR}"/card*-*/status; do
        connector="${status%/status}"
        connector="${connector##*/}"
        case "${connector}" in
            *-HDMI-*|*-DP-*|*-eDP-*|*-DSI-*|*-VGA-*|*-DVI-*) ;;
            *) continue ;;
        esac
        state="$(cat "${status}" 2>/dev/null || true)"
        if [[ "${state}" == "connected" ]]; then
            return 0
        fi
    done
    return 1
}

display_ready() {
    local display_name="$1"
    if [[ "${SKIP_X_CHECK}" == "1" ]]; then
        return 0
    fi
    command -v xset >/dev/null 2>&1 && DISPLAY="${display_name}" xset q >/dev/null 2>&1
}

choose_display() {
    if physical_connector_connected && display_ready "${PHYSICAL_DISPLAY}"; then
        printf '%s\n' "${PHYSICAL_DISPLAY}"
    else
        printf '%s\n' "${GHOST_DISPLAY}"
    fi
}

if [[ "${1:-}" == "--print" ]]; then
    choose_display
    exit 0
fi

export DISPLAY="$(choose_display)"
if [[ $# -eq 0 ]]; then
    set -- rustdesk
fi
exec "$@"
