#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="${GHOST_X11_COMMAND:-${SCRIPT_DIR}/ghost-display-x11.sh}"

if ! [[ -x "${launcher}" ]]; then
  launcher="$(command -v ghost-display-x11 || true)"
fi
[[ -n "${launcher}" ]] || { echo "ghost-display-x11 was not found" >&2; exit 1; }

export GHOST_DISPLAY_NUM="${GHOST_DISPLAY_NUM:-99}"
export GHOST_DISPLAY="${GHOST_DISPLAY:-:${GHOST_DISPLAY_NUM}}"
export GHOST_MONITORS="${GHOST_MONITORS:-1}"
export GHOST_RESOLUTION="${GHOST_RESOLUTION:-1920x1080}"
export GHOST_LAYOUT="${GHOST_LAYOUT:-horizontal}"

exec "${launcher}" --foreground "$@"
