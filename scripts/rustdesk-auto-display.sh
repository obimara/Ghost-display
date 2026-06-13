#!/usr/bin/env bash
set -euo pipefail

PHYSICAL_DISPLAY="${RUSTDESK_PHYSICAL_DISPLAY:-:0}"
GHOST_DISPLAY="${RUSTDESK_GHOST_DISPLAY:-:20}"
DRM_DIR="${RUSTDESK_DRM_DIR:-/sys/class/drm}"
SKIP_X_CHECK="${RUSTDESK_SKIP_X_CHECK:-0}"
PREFER_WAYLAND="${RUSTDESK_PREFER_WAYLAND:-1}"
WAYLAND_RUNTIME_DIR="${RUSTDESK_WAYLAND_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-}}"

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

wayland_socket_ready() {
    local socket_path

    [[ -n "${WAYLAND_DISPLAY:-}" ]] || return 1

    if [[ "${WAYLAND_DISPLAY}" = /* ]]; then
        socket_path="${WAYLAND_DISPLAY}"
    else
        [[ -n "${WAYLAND_RUNTIME_DIR}" ]] || return 1
        socket_path="${WAYLAND_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    fi

    [[ -S "${socket_path}" ]]
}

wayland_session_ready() {
    [[ "${PREFER_WAYLAND}" == "1" ]] || return 1
    [[ "${XDG_SESSION_TYPE:-wayland}" == "wayland" ]] || return 1
    wayland_socket_ready
}

display_ready() {
    local display_name="$1"
    if [[ "${SKIP_X_CHECK}" == "1" ]]; then
        return 0
    fi
    command -v xset >/dev/null 2>&1 && DISPLAY="${display_name}" xset q >/dev/null 2>&1
}

choose_mode() {
    if physical_connector_connected; then
        if wayland_session_ready; then
            printf 'wayland\n'
            return
        fi
        if display_ready "${PHYSICAL_DISPLAY}"; then
            printf 'x11\n'
            return
        fi
    fi
    printf 'ghost\n'
}

print_choice() {
    case "$(choose_mode)" in
        wayland) printf 'wayland:%s\n' "${WAYLAND_DISPLAY}" ;;
        x11) printf '%s\n' "${PHYSICAL_DISPLAY}" ;;
        ghost) printf '%s\n' "${GHOST_DISPLAY}" ;;
    esac
}

if [[ "${1:-}" == "--print" ]]; then
    print_choice
    exit 0
fi

case "$(choose_mode)" in
    wayland)
        ;;
    x11)
        export DISPLAY="${PHYSICAL_DISPLAY}"
        ;;
    ghost)
        export DISPLAY="${GHOST_DISPLAY}"
        ;;
esac

if [[ $# -eq 0 ]]; then
    set -- rustdesk
fi
exec "$@"
