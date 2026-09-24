#!/usr/bin/env bash
set -euo pipefail

PHYSICAL_DISPLAY="${GHOST_PHYSICAL_DISPLAY:-:0}"
GHOST_DISPLAY="${GHOST_DISPLAY:-:20}"
DRM_DIR="${GHOST_DRM_DIR:-/sys/class/drm}"
SKIP_X_CHECK="${GHOST_SKIP_X_CHECK:-0}"

display_ready() {
  [[ "${SKIP_X_CHECK}" == "1" ]] ||
    { command -v xset >/dev/null 2>&1 && DISPLAY="$1" xset q >/dev/null 2>&1; }
}

physical_display_connected() {
  local status connector state
  shopt -s nullglob
  for status in "${DRM_DIR}"/card*-*/status; do
    connector="${status%/status}"
    connector="${connector##*/}"
    case "${connector}" in
      *-HDMI-*|*-DP-*|*-eDP-*|*-DSI-*|*-VGA-*|*-DVI-*) ;;
      *) continue ;;
    esac
    read -r state <"${status}" 2>/dev/null || continue
    [[ "${state}" == "connected" ]] && return 0
  done
  return 1
}

choose_display() {
  if physical_display_connected && display_ready "${PHYSICAL_DISPLAY}"; then
    printf '%s\n' "${PHYSICAL_DISPLAY}"
  else
    printf '%s\n' "${GHOST_DISPLAY}"
  fi
}

if [[ "${1:-}" == "--print" ]]; then
  choose_display
  exit 0
fi

[[ $# -gt 0 ]] || { echo "Usage: ghost-display-auto-run COMMAND [ARG...]" >&2; exit 2; }
export DISPLAY="$(choose_display)"
exec "$@"
