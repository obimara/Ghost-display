#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${GHOST_DISPLAY_NUM:-20}"
DISPLAY_NAME="${GHOST_DISPLAY:-:${DISPLAY_NUM}}"
CONFIG_FILE="${GHOST_XORG_CONFIG:-/etc/X11/ghost-display.conf}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/ghost-display-${UID}}"
PID_FILE="${GHOST_PID_FILE:-${RUNTIME_DIR}/ghost-display-${DISPLAY_NUM}.pid}"
LOG_FILE="${GHOST_XORG_LOG:-/tmp/ghost-display-${DISPLAY_NUM}.log}"

VIRTUAL_MONITORS="${GHOST_MONITORS:-2}"
VIRTUAL_RESOLUTION="${GHOST_RESOLUTION:-${GHOST_WIDTH:-1920}x${GHOST_HEIGHT:-1080}}"
VIRTUAL_SCALE="${GHOST_SCALE:-1.0}"
VIRTUAL_DPI="${GHOST_DPI:-96}"
VIRTUAL_LAYOUT="${GHOST_LAYOUT:-horizontal}"
VIRTUAL_NAME_PREFIX="${GHOST_NAME_PREFIX:-Ghost}"
VIRTUAL_MONITOR_SPECS="${GHOST_MONITOR_SPECS:-}"

DRY_RUN="${GHOST_DRY_RUN:-0}"
FOREGROUND="${GHOST_STAY_FOREGROUND:-0}"
OWNED_XORG_PID=""

VIRTUAL_MAX_WIDTH="${GHOST_MAX_WIDTH:-8192}"
VIRTUAL_MAX_HEIGHT="${GHOST_MAX_HEIGHT:-8192}"

usage() {
  cat <<'USAGE'
Usage: ghost-display-x11 [--dry-run] [--foreground]

Starts an Xorg dummy display and exposes logical XRandR monitors for RustDesk.

Environment options:
  GHOST_DISPLAY_NUM=20
  GHOST_DISPLAY=:20
  GHOST_XORG_CONFIG=/etc/X11/ghost-display.conf
  GHOST_MONITORS=2
  GHOST_RESOLUTION=1920x1080
  GHOST_SCALE=1.0
  GHOST_DPI=96
  GHOST_LAYOUT=horizontal
  GHOST_NAME_PREFIX=Ghost
  GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25
  GHOST_MAX_WIDTH=8192
  GHOST_MAX_HEIGHT=8192
  GHOST_XORG_LOG=/tmp/ghost-display-20.log
  GHOST_STAY_FOREGROUND=1

Examples:
  GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 ghost-display-x11
  GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25 ghost-display-x11
  ghost-display-x11 --dry-run
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --foreground)
      FOREGROUND=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

# Locate the same profile implementation in a checkout or installed layout.
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_LIB="${SCRIPT_ROOT}/lib/monitor-profile.sh"
[[ -f "$PROFILE_LIB" ]] || PROFILE_LIB="${SCRIPT_ROOT}/lib/ghost-display-x11/monitor-profile.sh"
# shellcheck source=lib/monitor-profile.sh
source "$PROFILE_LIB"
loge() { printf '%s\n' "$*" >&2; }

print_plan() {
  echo "Ghost X11 display plan"
  echo "  DISPLAY=${DISPLAY_NAME}"
  echo "  config=${CONFIG_FILE}"
  echo "  log=${LOG_FILE}"
  echo "  framebuffer=${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"
  echo "  dpi=${VIRTUAL_DPI}"

  for i in "${!MONITOR_NAMES[@]}"; do
    echo "  ${MONITOR_NAMES[i]}: ${MONITOR_WIDTHS[i]}x${MONITOR_HEIGHTS[i]}+${MONITOR_X[i]}+${MONITOR_Y[i]} (${MONITOR_MM_WIDTHS[i]}x${MONITOR_MM_HEIGHTS[i]}mm)"
  done
}

is_xorg_running() {
  DISPLAY="${DISPLAY_NAME}" xset q >/dev/null 2>&1
}

cleanup_xorg() {
  if [[ -n "${OWNED_XORG_PID}" ]]; then
    kill "${OWNED_XORG_PID}" 2>/dev/null || true
    wait "${OWNED_XORG_PID}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    OWNED_XORG_PID=""
  fi
}

wait_for_xorg() {
  for _ in {1..40}; do
    if ! kill -0 "${OWNED_XORG_PID}" 2>/dev/null; then
      echo "Xorg exited before becoming ready. Check ${LOG_FILE}" >&2
      return 1
    fi
    if is_xorg_running; then
      return 0
    fi
    sleep 0.25
  done

  echo "Xorg did not become ready. Check ${LOG_FILE}" >&2
  return 1
}

start_xorg() {
  if [[ -z "${GHOST_PID_FILE:-}" ]]; then
    if [[ ! -e "${RUNTIME_DIR}" ]]; then
      mkdir -m 0700 -- "${RUNTIME_DIR}"
    fi
    if [[ ! -d "${RUNTIME_DIR}" || -L "${RUNTIME_DIR}" || ! -O "${RUNTIME_DIR}" ]] ||
       [[ "$(stat -c %a -- "${RUNTIME_DIR}")" != "700" ]]; then
      echo "Runtime directory must be owned by this user with mode 0700: ${RUNTIME_DIR}" >&2
      return 1
    fi
  fi

  Xorg "${DISPLAY_NAME}" \
    -config "${CONFIG_FILE}" \
    -noreset \
    +extension RANDR \
    -logfile "${LOG_FILE}" \
    >/dev/null 2>&1 &

  OWNED_XORG_PID=$!
  trap cleanup_xorg EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  echo "${OWNED_XORG_PID}" >"${PID_FILE}"
  wait_for_xorg
}

start_xorg_background() {
  if ! is_xorg_running; then
    start_xorg
  fi
}

start_xorg_foreground() {
  if is_xorg_running; then
    echo "An X server already answers on ${DISPLAY_NAME}; stop it before starting the foreground service." >&2
    return 1
  fi

  start_xorg
  configure_monitors
  print_plan
  echo "RustDesk should be started with DISPLAY=${DISPLAY_NAME}."
  wait "${OWNED_XORG_PID}"
}

configure_monitors() {
  DISPLAY="${DISPLAY_NAME}" xrandr --fb "${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"

  while read -r monitor_name; do
    [[ "${monitor_name}" == "${VIRTUAL_NAME_PREFIX}-"* ]] || continue
    DISPLAY="${DISPLAY_NAME}" xrandr --delmonitor "${monitor_name}" >/dev/null 2>&1 || true
  done < <(
    DISPLAY="${DISPLAY_NAME}" xrandr --listmonitors |
      awk 'NR > 1 { name = $2; sub(/^\+\*/, "", name); sub(/^\+/, "", name); sub(/^\*/, "", name); print name }'
  )

  for i in "${!MONITOR_NAMES[@]}"; do
    DISPLAY="${DISPLAY_NAME}" xrandr --setmonitor \
      "${MONITOR_NAMES[i]}" \
      "${MONITOR_WIDTHS[i]}/${MONITOR_MM_WIDTHS[i]}x${MONITOR_HEIGHTS[i]}/${MONITOR_MM_HEIGHTS[i]}+${MONITOR_X[i]}+${MONITOR_Y[i]}" \
      none
  done

  printf 'Xft.dpi: %s\n' "${VIRTUAL_DPI}" | DISPLAY="${DISPLAY_NAME}" xrdb -merge
}

main() {
  build_monitor_specs || return 2

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_plan
    return
  fi

  require_command Xorg
  require_command xrandr
  require_command xset
  require_command xrdb

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Missing Xorg config: ${CONFIG_FILE}" >&2
    exit 1
  fi

  if [[ "${FOREGROUND}" == "1" ]]; then
    start_xorg_foreground
    return
  fi

  start_xorg_background
  configure_monitors
  # Successful detached starts outlive this launcher; failures still clean up.
  trap - EXIT INT TERM
  OWNED_XORG_PID=""
  print_plan
  echo "RustDesk should be started with DISPLAY=${DISPLAY_NAME}."
}

main "$@"
