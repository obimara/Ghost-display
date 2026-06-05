#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${GHOST_DISPLAY_NUM:-20}"
DISPLAY_NAME="${GHOST_DISPLAY:-:${DISPLAY_NUM}}"
CONFIG_FILE="${GHOST_XORG_CONFIG:-/etc/X11/ghost-display.conf}"
PID_FILE="${GHOST_PID_FILE:-${XDG_RUNTIME_DIR:-/tmp}/ghost-display-${DISPLAY_NUM}.pid}"
LOG_FILE="${GHOST_XORG_LOG:-/tmp/ghost-display-${DISPLAY_NUM}.log}"

MONITORS="${GHOST_MONITORS:-2}"
RESOLUTION="${GHOST_RESOLUTION:-${GHOST_WIDTH:-1920}x${GHOST_HEIGHT:-1080}}"
SCALE="${GHOST_SCALE:-1.0}"
DPI="${GHOST_DPI:-96}"
LAYOUT="${GHOST_LAYOUT:-horizontal}"
NAME_PREFIX="${GHOST_NAME_PREFIX:-Ghost}"
MONITOR_SPECS="${GHOST_MONITOR_SPECS:-}"

DRY_RUN="${GHOST_DRY_RUN:-0}"
FOREGROUND="${GHOST_STAY_FOREGROUND:-0}"

MAX_WIDTH="${GHOST_MAX_WIDTH:-8192}"
MAX_HEIGHT="${GHOST_MAX_HEIGHT:-8192}"

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

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_positive_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

scale_pixels() {
  local pixels="$1"
  local scale="$2"
  awk -v pixels="${pixels}" -v scale="${scale}" 'BEGIN { printf "%d", (pixels * scale) + 0.5 }'
}

pixels_to_mm() {
  local pixels="$1"
  local dpi="$2"
  local mm

  mm="$(awk -v pixels="${pixels}" -v dpi="${dpi}" 'BEGIN { printf "%d", (pixels * 25.4 / dpi) + 0.5 }')"

  if [[ "${mm}" -lt 1 ]]; then
    mm=1
  fi

  printf '%s' "${mm}"
}

parse_resolution() {
  local value="$1"

  if [[ ! "${value}" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
    echo "Invalid resolution '${value}'. Use WIDTHxHEIGHT, for example 1920x1080." >&2
    exit 2
  fi

  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

validate_options() {
  if ! is_positive_int "${MONITORS}"; then
    echo "GHOST_MONITORS must be a positive integer." >&2
    exit 2
  fi

  if ! is_positive_number "${SCALE}"; then
    echo "GHOST_SCALE must be a positive number." >&2
    exit 2
  fi

  if ! is_positive_number "${DPI}"; then
    echo "GHOST_DPI must be a positive number." >&2
    exit 2
  fi

  if [[ "${LAYOUT}" != "horizontal" && "${LAYOUT}" != "vertical" ]]; then
    echo "GHOST_LAYOUT must be 'horizontal' or 'vertical'." >&2
    exit 2
  fi

  if ! is_positive_int "${MAX_WIDTH}" || ! is_positive_int "${MAX_HEIGHT}"; then
    echo "GHOST_MAX_WIDTH and GHOST_MAX_HEIGHT must be positive integers." >&2
    exit 2
  fi
}

build_monitor_specs() {
  local raw_specs=()
  local base_width
  local base_height
  local spec
  local spec_resolution
  local spec_scale
  local width
  local height
  local effective_width
  local effective_height
  local mm_width
  local mm_height
  local offset_x=0
  local offset_y=0
  local index=1

  MONITOR_NAMES=()
  MONITOR_WIDTHS=()
  MONITOR_HEIGHTS=()
  MONITOR_MM_WIDTHS=()
  MONITOR_MM_HEIGHTS=()
  MONITOR_X=()
  MONITOR_Y=()

  if [[ -n "${MONITOR_SPECS}" ]]; then
    IFS=',' read -r -a raw_specs <<<"${MONITOR_SPECS}"
  else
    read -r base_width base_height <<<"$(parse_resolution "${RESOLUTION}")"
    for ((i = 1; i <= MONITORS; i++)); do
      raw_specs+=("${base_width}x${base_height}@${SCALE}")
    done
  fi

  for spec in "${raw_specs[@]}"; do
    spec="${spec//[[:space:]]/}"

    if [[ "${spec}" == *"@"* ]]; then
      spec_resolution="${spec%@*}"
      spec_scale="${spec##*@}"
    else
      spec_resolution="${spec}"
      spec_scale="${SCALE}"
    fi

    read -r width height <<<"$(parse_resolution "${spec_resolution}")"

    if ! is_positive_number "${spec_scale}"; then
      echo "Invalid scale '${spec_scale}' in GHOST_MONITOR_SPECS." >&2
      exit 2
    fi

    effective_width="$(scale_pixels "${width}" "${spec_scale}")"
    effective_height="$(scale_pixels "${height}" "${spec_scale}")"
    mm_width="$(pixels_to_mm "${effective_width}" "${DPI}")"
    mm_height="$(pixels_to_mm "${effective_height}" "${DPI}")"

    MONITOR_NAMES+=("${NAME_PREFIX}-${index}")
    MONITOR_WIDTHS+=("${effective_width}")
    MONITOR_HEIGHTS+=("${effective_height}")
    MONITOR_MM_WIDTHS+=("${mm_width}")
    MONITOR_MM_HEIGHTS+=("${mm_height}")
    MONITOR_X+=("${offset_x}")
    MONITOR_Y+=("${offset_y}")

    if [[ "${LAYOUT}" == "horizontal" ]]; then
      offset_x=$((offset_x + effective_width))
    else
      offset_y=$((offset_y + effective_height))
    fi

    index=$((index + 1))
  done

  FRAMEBUFFER_WIDTH=0
  FRAMEBUFFER_HEIGHT=0

  for i in "${!MONITOR_NAMES[@]}"; do
    local right=$((MONITOR_X[i] + MONITOR_WIDTHS[i]))
    local bottom=$((MONITOR_Y[i] + MONITOR_HEIGHTS[i]))

    if (( right > FRAMEBUFFER_WIDTH )); then
      FRAMEBUFFER_WIDTH="${right}"
    fi

    if (( bottom > FRAMEBUFFER_HEIGHT )); then
      FRAMEBUFFER_HEIGHT="${bottom}"
    fi
  done

  if (( FRAMEBUFFER_WIDTH > MAX_WIDTH || FRAMEBUFFER_HEIGHT > MAX_HEIGHT )); then
    echo "Requested framebuffer ${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT} exceeds ${MAX_WIDTH}x${MAX_HEIGHT}." >&2
    echo "Increase the Xorg Virtual size/VideoRam and set GHOST_MAX_WIDTH/GHOST_MAX_HEIGHT to match." >&2
    exit 2
  fi
}

print_plan() {
  echo "Ghost X11 display plan"
  echo "  DISPLAY=${DISPLAY_NAME}"
  echo "  config=${CONFIG_FILE}"
  echo "  framebuffer=${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"
  echo "  dpi=${DPI}"

  for i in "${!MONITOR_NAMES[@]}"; do
    echo "  ${MONITOR_NAMES[i]}: ${MONITOR_WIDTHS[i]}x${MONITOR_HEIGHTS[i]}+${MONITOR_X[i]}+${MONITOR_Y[i]} (${MONITOR_MM_WIDTHS[i]}x${MONITOR_MM_HEIGHTS[i]}mm)"
  done
}

is_xorg_running() {
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    return 0
  fi

  pgrep -f "Xorg ${DISPLAY_NAME} .*${CONFIG_FILE}" >/dev/null 2>&1
}

wait_for_xorg() {
  for _ in {1..40}; do
    if DISPLAY="${DISPLAY_NAME}" xset q >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  echo "Xorg did not become ready. Check ${LOG_FILE}" >&2
  return 1
}

start_xorg_background() {
  if is_xorg_running; then
    return 0
  fi

  Xorg "${DISPLAY_NAME}" \
    -config "${CONFIG_FILE}" \
    -noreset \
    +extension RANDR \
    -logfile "${LOG_FILE}" \
    >/dev/null 2>&1 &

  echo "$!" >"${PID_FILE}"
  wait_for_xorg
}

start_xorg_foreground() {
  if is_xorg_running; then
    echo "Xorg already appears to be running for ${DISPLAY_NAME}." >&2
    wait_for_xorg
    wait "$(cat "${PID_FILE}")"
    return
  fi

  Xorg "${DISPLAY_NAME}" \
    -config "${CONFIG_FILE}" \
    -noreset \
    +extension RANDR \
    -logfile "${LOG_FILE}" \
    >/dev/null 2>&1 &

  local xorg_pid=$!
  echo "${xorg_pid}" >"${PID_FILE}"

  trap 'kill "${xorg_pid}" 2>/dev/null || true; rm -f "${PID_FILE}"' EXIT INT TERM

  wait_for_xorg
  configure_monitors
  print_plan
  echo "RustDesk should be started with DISPLAY=${DISPLAY_NAME}."

  wait "${xorg_pid}"
}

configure_monitors() {
  DISPLAY="${DISPLAY_NAME}" xrandr --fb "${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"

  while read -r monitor_name; do
    [[ "${monitor_name}" == "${NAME_PREFIX}-"* ]] || continue
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

  printf 'Xft.dpi: %s\n' "${DPI}" | DISPLAY="${DISPLAY_NAME}" xrdb -merge
}

main() {
  validate_options
  build_monitor_specs

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
  print_plan
  echo "RustDesk should be started with DISPLAY=${DISPLAY_NAME}."
}

main "$@"
