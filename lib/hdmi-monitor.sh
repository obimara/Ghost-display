#!/usr/bin/env bash
# lib/hdmi-monitor.sh - HDMI hotplug detection module for Ghost Display
# Provides hdmi_connected() function and HDMI state monitoring

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh
# Make sure these are sourced before this file

# =============================================================================
# HDMI CONNECTION DETECTION
# =============================================================================

# Check if any HDMI port has a connected display
# Uses pure bash read - no subshell, no tr, no external commands
hdmi_connected() {
    local f val
    for f in "${HDMI_DRM_ROOT}"/card*-HDMI-A-*/status; do
        [[ -f "$f" ]] || continue
        # Pure bash read - FIX B4 from AlwaysX11
        read -r val < "$f" 2>/dev/null || continue
        [[ "$val" == "connected" ]] && return 0
    done
    return 1
}

# Get list of connected HDMI ports
get_connected_ports() {
    local ports=()
    local f val
    for f in "${HDMI_DRM_ROOT}"/card*-HDMI-A-*/status; do
        [[ -f "$f" ]] || continue
        read -r val < "$f" 2>/dev/null || continue
        if [[ "$val" == "connected" ]]; then
            local port
            port="$(dirname "$f")"
            ports+=("$port")
        fi
    done
    printf '%s\n' "${ports[@]}"
}

# Count connected HDMI ports
hdmi_connected_count() {
    local count=0
    local f val
    for f in "${HDMI_DRM_ROOT}"/card*-HDMI-A-*/status; do
        [[ -f "$f" ]] || continue
        read -r val < "$f" 2>/dev/null || continue
        [[ "$val" == "connected" ]] && count=$((count + 1))
    done
    echo "$count"
}

# =============================================================================
# HDMI STATE MONITORING
# =============================================================================

# Monitor HDMI state with debouncing
# Returns: "connected" or "disconnected" after stable detection
monitor_hdmi_state() {
    local stable_count=0
    local last_state=""
    local current_state
    
    # Initial state
    if hdmi_connected; then
        current_state="connected"
    else
        current_state="disconnected"
    fi
    
    # Monitor for changes with debouncing
    while true; do
        if hdmi_connected; then
            if [[ "$current_state" != "connected" ]]; then
                current_state="connected"
                stable_count=0
                logd "HDMI state changed to: connected"
            else
                stable_count=$((stable_count + 1))
            fi
        else
            if [[ "$current_state" != "disconnected" ]]; then
                current_state="disconnected"
                stable_count=0
                logd "HDMI state changed to: disconnected"
            else
                stable_count=$((stable_count + 1))
            fi
        fi
        
        # Check if state is stable
        if (( stable_count >= HDMI_STABLE_SECONDS )); then
            echo "$current_state"
            return 0
        fi
        
        sleep "$HDMI_POLL_INTERVAL"
    done
}

# =============================================================================
# HDMI EVENT HANDLING
# =============================================================================

# Wait for HDMI connection
hdmi_wait_for_connection() {
    local timeout="${1:-30}"
    local elapsed=0
    
    while (( elapsed < timeout )); do
        if hdmi_connected; then
            logi "HDMI connection detected"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    logw "HDMI connection not detected within ${timeout}s"
    return 1
}

# Wait for HDMI disconnection
hdmi_wait_for_disconnection() {
    local timeout="${1:-30}"
    local elapsed=0
    
    while (( elapsed < timeout )); do
        if ! hdmi_connected; then
            logi "HDMI disconnection detected"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    logw "HDMI disconnection not detected within ${timeout}s"
    return 1
}
