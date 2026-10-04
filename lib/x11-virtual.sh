#!/usr/bin/env bash
# lib/x11-virtual.sh - Virtual X11 display management for Ghost Display
# Based on ghost-display-x11.sh with enhancements

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh

# Both launchers share profile parsing and geometry.
# shellcheck source=lib/monitor-profile.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-profile.sh"

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
