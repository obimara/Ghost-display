#!/usr/bin/env bash
# lib/x11-virtual.sh - Virtual X11 display management for Ghost Display
# Based on ghost-display-x11.sh with enhancements

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

scale_pixels() {
    local pixels="$1"
    local scale="$2"
    awk -v pixels="${pixels}" -v scale="${scale}" 'BEGIN { value = int(pixels * scale + 0.5); if (!(value >= 1 && value <= 32767)) exit 1; printf "%d", value }'
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
        loge "Invalid resolution '${value}'. Use WIDTHxHEIGHT, for example 1920x1080."
        return 1
    fi
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# =============================================================================
# MONITOR SPECIFICATION BUILDING
# =============================================================================

# Global arrays for monitor specs (will be set by build_monitor_specs)
declare -a MONITOR_NAMES=()
declare -a MONITOR_WIDTHS=()
declare -a MONITOR_HEIGHTS=()
declare -a MONITOR_MM_WIDTHS=()
declare -a MONITOR_MM_HEIGHTS=()
declare -a MONITOR_X=()
declare -a MONITOR_Y=()
declare FRAMEBUFFER_WIDTH=0
declare FRAMEBUFFER_HEIGHT=0

build_monitor_specs() {
    local raw_specs=()
    local parsed i
    if ! is_positive_int "${VIRTUAL_MONITORS}" || (( ${#VIRTUAL_MONITORS} > 2 )) || (( VIRTUAL_MONITORS > 64 )); then
        loge "VIRTUAL_MONITORS must be between 1 and 64."
        return 1
    fi
    if ! is_positive_number "${VIRTUAL_DPI}" || ! awk -v dpi="${VIRTUAL_DPI}" 'BEGIN { exit !(dpi >= 1 && dpi <= 10000) }'; then
        loge "VIRTUAL_DPI must be between 1 and 10000."
        return 1
    fi
    if [[ "${VIRTUAL_LAYOUT}" != horizontal && "${VIRTUAL_LAYOUT}" != vertical ]]; then
        loge "VIRTUAL_LAYOUT must be horizontal or vertical."
        return 1
    fi
    local limit
    for limit in "${VIRTUAL_MAX_WIDTH}" "${VIRTUAL_MAX_HEIGHT}"; do
        if ! is_positive_int "$limit" || (( ${#limit} > 5 )) || (( limit > 32767 )); then
            loge "Framebuffer limits must be between 1 and 32767."
            return 1
        fi
    done
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

    # Reset global arrays
    MONITOR_NAMES=()
    MONITOR_WIDTHS=()
    MONITOR_HEIGHTS=()
    MONITOR_MM_WIDTHS=()
    MONITOR_MM_HEIGHTS=()
    MONITOR_X=()
    MONITOR_Y=()

    if [[ -n "${VIRTUAL_MONITOR_SPECS}" ]]; then
        if [[ "${VIRTUAL_MONITOR_SPECS}" == *, ]]; then
            loge "Empty monitor specification."
            return 1
        fi
        IFS=',' read -r -a raw_specs <<<"${VIRTUAL_MONITOR_SPECS}"
        if (( ${#raw_specs[@]} > 64 )); then
            loge "At most 64 virtual monitors are supported."
            return 1
        fi
    else
        parsed="$(parse_resolution "${VIRTUAL_RESOLUTION}")" || return 1
        read -r base_width base_height <<<"$parsed"
        for ((i = 1; i <= VIRTUAL_MONITORS; i++)); do
            raw_specs+=("${base_width}x${base_height}@${VIRTUAL_SCALE}")
        done
    fi

    for spec in "${raw_specs[@]}"; do
        spec="${spec//[[:space:]]/}"

        if [[ "${spec}" == *"@"* ]]; then
            spec_resolution="${spec%@*}"
            spec_scale="${spec##*@}"
        else
            spec_resolution="${spec}"
            spec_scale="${VIRTUAL_SCALE}"
        fi

        parsed="$(parse_resolution "${spec_resolution}")" || return 1
        read -r width height <<<"$parsed"

        if ! is_positive_number "${spec_scale}"; then
            loge "Invalid scale '${spec_scale}' in VIRTUAL_MONITOR_SPECS."
            return 1
        fi

        if ! effective_width="$(scale_pixels "${width}" "${spec_scale}")" ||
           ! effective_height="$(scale_pixels "${height}" "${spec_scale}")"; then
            loge "Scaled monitor dimensions must be between 1 and 32767 pixels."
            return 1
        fi
        mm_width="$(pixels_to_mm "${effective_width}" "${VIRTUAL_DPI}")"
        mm_height="$(pixels_to_mm "${effective_height}" "${VIRTUAL_DPI}")"

        MONITOR_NAMES+=("${VIRTUAL_NAME_PREFIX}-${index}")
        MONITOR_WIDTHS+=("${effective_width}")
        MONITOR_HEIGHTS+=("${effective_height}")
        MONITOR_MM_WIDTHS+=("${mm_width}")
        MONITOR_MM_HEIGHTS+=("${mm_height}")
        MONITOR_X+=("${offset_x}")
        MONITOR_Y+=("${offset_y}")

        if [[ "${VIRTUAL_LAYOUT}" == "horizontal" ]]; then
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

    if (( FRAMEBUFFER_WIDTH > VIRTUAL_MAX_WIDTH || FRAMEBUFFER_HEIGHT > VIRTUAL_MAX_HEIGHT )); then
        loge "Requested framebuffer ${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT} exceeds ${VIRTUAL_MAX_WIDTH}x${VIRTUAL_MAX_HEIGHT}."
        loge "Increase the Xorg Virtual size/VideoRam and set VIRTUAL_MAX_WIDTH/VIRTUAL_MAX_HEIGHT to match."
        return 1
    fi
    
    return 0
}

print_virtual_plan() {
    logi "Virtual X11 display plan"
    logi "  DISPLAY=${VIRTUAL_DISPLAY}"
    logi "  config=${DUMMY_XORG_CONF}"
    logi "  framebuffer=${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}"
    logi "  dpi=${VIRTUAL_DPI}"

    for i in "${!MONITOR_NAMES[@]}"; do
        logi "  ${MONITOR_NAMES[i]}: ${MONITOR_WIDTHS[i]}x${MONITOR_HEIGHTS[i]}+${MONITOR_X[i]}+${MONITOR_Y[i]} (${MONITOR_MM_WIDTHS[i]}x${MONITOR_MM_HEIGHTS[i]}mm)"
    done
}

# =============================================================================
# XORG MANAGEMENT
# =============================================================================

# Check if Xorg is running for the virtual display
virtual_is_xorg_running() {
    [[ -f "${DUMMY_PID_FILE}" ]] || return 1
    local pid arg display_found=0 config_found=0 previous=""
    pid=$(cat "${DUMMY_PID_FILE}") || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local -a args=()
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
    (( ${#args[@]} > 0 )) || return 1
    [[ "${args[0]##*/}" == Xorg || "${args[0]}" == "${XORG_BIN}" ]] || return 1
    for arg in "${args[@]:1}"; do
        [[ "$arg" == "${VIRTUAL_DISPLAY}" ]] && display_found=1
        [[ "$previous" == -config && "$arg" == "${DUMMY_XORG_CONF}" ]] && config_found=1
        previous="$arg"
    done
    (( display_found && config_found ))
}

# Wait for Xorg to become ready
virtual_wait_for_xorg() {
    local max_tries=40
    local i=0
    
    while (( i < max_tries )); do
        if DISPLAY="${VIRTUAL_DISPLAY}" xset q >/dev/null 2>&1; then
            logd "Xorg is ready on ${VIRTUAL_DISPLAY}"
            return 0
        fi
        sleep 0.25
        i=$((i + 1))
    done

    loge "Xorg did not become ready within ${max_tries} tries. Check ${XORG_LOG_DIR}/xorg-dummy.log"
    return 1
}

# Start Xorg for virtual display
virtual_start_xorg() {
    if virtual_is_xorg_running; then
        logi "Xorg already running on ${VIRTUAL_DISPLAY}"
        return 0
    fi
    if DISPLAY="${VIRTUAL_DISPLAY}" xset q >/dev/null 2>&1; then
        loge "Display ${VIRTUAL_DISPLAY} is already in use by an unmanaged server."
        return 1
    fi
    # Xorg manages its own locks; never unlink another server's socket.
    # Ensure Xorg config exists
    if [[ ! -f "$DUMMY_XORG_CONF" ]]; then
        loge "Xorg config missing: $DUMMY_XORG_CONF"
        return 1
    fi
    
    # Ensure log directory exists (FIX B4 from AlwaysX11)
    mkdir -p "$XORG_LOG_DIR" || return 1
    local xlog="${XORG_LOG_DIR}/xorg-dummy.log"
    
    # Start Xorg
    logi "Starting Xorg on ${VIRTUAL_DISPLAY}"
    "${XORG_BIN}" "${VIRTUAL_DISPLAY}" \
        -config "${DUMMY_XORG_CONF}" \
        -noreset -nolisten tcp \
        -logfile "${xlog}" \
        >/dev/null 2>&1 &
    
    local pid=$!
    if ! printf '%s\n' "$pid" > "$DUMMY_PID_FILE"; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
    fi
    logd "Xorg PID=$pid on ${VIRTUAL_DISPLAY}"

    return 0
}

# Stop Xorg for virtual display
virtual_stop_xorg() {
    if [[ -f "$DUMMY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$DUMMY_PID_FILE" 2>/dev/null || echo "")
        if virtual_is_xorg_running; then
            logi "Stopping Xorg PID=$pid"
            kill -TERM "$pid" 2>/dev/null || true
            local i=0
            while (( i < 40 )); do
                virtual_is_xorg_running || break
                sleep 0.1
                i=$((i + 1))
            done
            if virtual_is_xorg_running; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$DUMMY_PID_FILE"
    fi
    
    # Let Xorg remove the lock and socket it owns.
}

# Configure monitors using xrandr
virtual_configure_monitors() {
    local listing monitor_name i
    DISPLAY="${VIRTUAL_DISPLAY}" xrandr --fb "${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT}" || return 1
    listing=$(DISPLAY="${VIRTUAL_DISPLAY}" xrandr --listmonitors) || return 1
    while read -r monitor_name; do
        [[ "${monitor_name}" == "${VIRTUAL_NAME_PREFIX}-"* ]] || continue
        DISPLAY="${VIRTUAL_DISPLAY}" xrandr --delmonitor "${monitor_name}" || return 1
    done < <(awk 'NR > 1 { name = $2; sub(/^[+*]+/, "", name); print name }' <<<"$listing")

    # Add new monitors
    for i in "${!MONITOR_NAMES[@]}"; do
        DISPLAY="${VIRTUAL_DISPLAY}" xrandr --setmonitor \
            "${MONITOR_NAMES[i]}" \
            "${MONITOR_WIDTHS[i]}/${MONITOR_MM_WIDTHS[i]}x${MONITOR_HEIGHTS[i]}/${MONITOR_MM_HEIGHTS[i]}+${MONITOR_X[i]}+${MONITOR_Y[i]}" \
            none || return 1
    done

    # Set DPI
    printf 'Xft.dpi: %s\n' "${VIRTUAL_DPI}" | DISPLAY="${VIRTUAL_DISPLAY}" xrdb -merge || return 1
    
    logi "Virtual monitors configured successfully"
}

# Start virtual display (main function)
virtual_start() {
    logi "Starting virtual display on ${VIRTUAL_DISPLAY}"
    
    # Validate options
    if ! is_positive_int "${VIRTUAL_MONITORS}"; then
        loge "VIRTUAL_MONITORS must be a positive integer."
        return 1
    fi
    
    if ! is_positive_number "${VIRTUAL_SCALE}"; then
        loge "VIRTUAL_SCALE must be a positive number."
        return 1
    fi
    
    if ! is_positive_number "${VIRTUAL_DPI}"; then
        loge "VIRTUAL_DPI must be a positive number."
        return 1
    fi
    
    if [[ "${VIRTUAL_LAYOUT}" != "horizontal" && "${VIRTUAL_LAYOUT}" != "vertical" ]]; then
        loge "VIRTUAL_LAYOUT must be 'horizontal' or 'vertical'."
        return 1
    fi
    
    # Build monitor specs
    if ! build_monitor_specs; then
        loge "Failed to build monitor specifications"
        return 1
    fi
    
    # Print plan
    print_virtual_plan
    
    # Check for required commands
    for cmd in "${XORG_BIN}" xrandr xset xrdb; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            loge "Missing required command: $cmd"
            return 1
        fi
    done
    
    # Check for Xorg config
    if [[ ! -f "$DUMMY_XORG_CONF" ]]; then
        loge "Missing Xorg config: $DUMMY_XORG_CONF"
        return 1
    fi
    
    # Preserve an existing managed server if reconfiguration fails.
    local already_running=0
    virtual_is_xorg_running && already_running=1
    # Start Xorg
    if ! virtual_start_xorg; then
        loge "Failed to start Xorg"
        return 1
    fi
    
    # Wait for Xorg to be ready
    if ! virtual_wait_for_xorg; then
        loge "Xorg did not become ready"
        (( already_running )) || virtual_stop_xorg
        return 1
    fi
    
    # Configure monitors
    if ! virtual_configure_monitors; then
        loge "Failed to configure monitors"
        (( already_running )) || virtual_stop_xorg
        return 1
    fi
    
    logi "Virtual display started successfully on ${VIRTUAL_DISPLAY}"
    logi "RustDesk should be started with DISPLAY=${VIRTUAL_DISPLAY}."
    
    return 0
}

# Stop virtual display
virtual_stop() {
    logi "Stopping virtual display on ${VIRTUAL_DISPLAY}"
    virtual_stop_xorg
    logi "Virtual display stopped"
    return 0
}

# Check if virtual display is running
virtual_is_running() {
    virtual_is_xorg_running
}
