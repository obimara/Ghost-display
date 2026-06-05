#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${GHOST_DISPLAY_NUM:-20}"
DISPLAY_NAME="${GHOST_DISPLAY:-:${DISPLAY_NUM}}"
CONFIG_FILE="${GHOST_XORG_CONFIG:-/etc/X11/ghost-display.conf}"
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/ghost-display-${DISPLAY_NUM}.pid"
LOG_FILE="${GHOST_XORG_LOG:-/tmp/ghost-display-${DISPLAY_NUM}.log}"
MONITORS="${GHOST_MONITORS:-2}"
RESOLUTION="${GHOST_RESOLUTION:-${GHOST_WIDTH:-1920}x${GHOST_HEIGHT:-1080}}"
SCALE="${GHOST_SCALE:-1.0}"
DPI="${GHOST_DPI:-96}"
LAYOUT="${GHOST_LAYOUT:-horizontal}"
NAME_PREFIX="${GHOST_NAME_PREFIX:-Ghost}"
MONITOR_SPECS="${GHOST_MONITOR_SPECS:-}"
DRY_RUN="${GHOST_DRY_RUN:-0}"
MAX_WIDTH="${GHOST_MAX_WIDTH:-8192}"
MAX_HEIGHT="${GHOST_MAX_HEIGHT:-8192}"

usage() {
    cat <<'USAGE'
Usage: ghost-display-x11 [--dry-run]

Starts an Xorg dummy display and exposes logical XRandR monitors for RustDesk.

Environment options:
  GHOST_DISPLAY_NUM=20             X display number used when GHOST_DISPLAY is unset.
  GHOST_DISPLAY=:20                Full X display name.
  GHOST_XORG_CONFIG=/path.conf     Xorg dummy config path.
  GHOST_MONITORS=2                 Number of identical logical monitors.
  GHOST_RESOLUTION=1920x1080       Base resolution for each monitor.
  GHOST_SCALE=1.0                  Pixel scale multiplier per monitor.
  GHOST_DPI=96                     Advertised monitor DPI and Xft.dpi.
  GHOST_LAYOUT=horizontal          horizontal or vertical placement.
  GHOST_NAME_PREFIX=Ghost          Monitor name prefix.
  GHOST_MONITOR_SPECS=...          Per-monitor specs, e.g. 1920x1080@1,2560x1440@1.25
  GHOST_DRY_RUN=1                  Print the plan without starting Xorg.
  GHOST_MAX_WIDTH=8192             Safety limit matching the sample Xorg Virtual width.
  GHOST_MAX_HEIGHT=8192            Safety limit matching the sample Xorg Virtual height.

Examples:
  GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 ghost-display-x11
  GHOST_MONITORS=3 GHOST_RESOLUTION=1280x720 GHOST_LAYOUT=vertical ghost-display-x11
  GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25 GHOST_DPI=110 ghost-display-x11
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
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

round_number() {
    awk 'BEGIN { printf "%d", ('"$1"') + 0.5 }'
}

scale_pixels() {
    local pixels="$1"
    local scale="$2"
    round_number "${pixels} * ${scale}"
}

pixels_to_mm() {
    local pixels="$1"
    local dpi="$2"
    local mm
    mm="$(round_number "${pixels} * 25.4 / ${dpi}")"
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
    local base_width base_height spec spec_resolution spec_scale width height effective_width effective_height mm_width mm_height

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

    local offset_x=0
    local offset_y=0
    local index=1

    for spec in "${raw_specs[@]}"; do
        spec="${spec//[[:space:]]/}"
        spec_resolution="${spec%@*}"
        if [[ "${spec}" == *"@"* ]]; then
            spec_scale="${spec##*@}"
        else
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

start_xorg() {
    if is_xorg_running; then
        return
    fi

    Xorg "${DISPLAY_NAME}" \
        -config "${CONFIG_FILE}" \
        -noreset \
        +extension RANDR \
        -logfile "${LOG_FILE}" \
        >/dev/null 2>&1 &

    echo "$!" >"${PID_FILE}"

    for _ in {1..40}; do
        if DISPLAY="${DISPLAY_NAME}" xset q >/dev/null 2>&1; then
            return
        fi
        sleep 0.25
    done

    echo "Xorg did not become ready. Check ${LOG_FILE}" >&2
    exit 1
}

configure_monitors() {
    DISPLAY="${DISPLAY_NAME}" xrandr --fb "${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"

    # Replace stale monitor definitions if the script is re-run.
    while read -r monitor_name; do
        [[ "${monitor_name}" == "${NAME_PREFIX}-"* ]] || continue
        DISPLAY="${DISPLAY_NAME}" xrandr --delmonitor "${monitor_name}" >/dev/null 2>&1 || true
    done < <(DISPLAY="${DISPLAY_NAME}" xrandr --listmonitors | awk 'NR > 1 { name = $2; sub(/^\+\*/, "", name); sub(/^\+/, "", name); sub(/^\*/, "", name); print name }')

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

    start_xorg
    configure_monitors
    print_plan
    echo "RustDesk should be started with DISPLAY=${DISPLAY_NAME}."
}

main "$@"
