#!/usr/bin/env bash
# lib/dm-manager.sh - Display Manager detection and control for Ghost Display
# Based on dm-detect.sh from AlwaysX11 with improvements

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh

# =============================================================================
# DISPLAY MANAGER DETECTION
# =============================================================================

# DM candidates: name|label
_DM_CANDIDATES=(
    "gdm|GNOME/GDM"
    "gdm3|GNOME/GDM3"
    "sddm|KDE/SDDM"
    "lightdm|LightDM"
    "lxdm|LXDE/LXDM"
    "xdm|XDM"
    "slim|SLiM"
    "nodm|nodm"
)

# Global variables (will be set by dm_detect)
DM_FOUND="false"
DM_SERVICE=""
DM_NAME="none"

dm_detect() {
    DM_FOUND="false"
    DM_SERVICE="${DM_SERVICE:-}"
    DM_NAME="none"

    # If DM_SERVICE is explicitly set, verify it exists
    if [[ -n "${DM_SERVICE:-}" ]]; then
        if systemctl cat "${DM_SERVICE}.service" &>/dev/null \
           || systemctl cat "${DM_SERVICE}" &>/dev/null; then
            DM_NAME="custom/${DM_SERVICE}"
            DM_FOUND="true"
            logd "Using forced DM_SERVICE: ${DM_SERVICE}"
            return 0
        fi
        logw "Forced DM_SERVICE='${DM_SERVICE}' not found - auto-detecting"
        DM_SERVICE=""
    fi

    # FIX B8 from AlwaysX11: init ALL label vars before loop - set -u safe
    local au="" eu="" iu="" al="" el="" il=""
    local unit label st en

    for candidate in "${_DM_CANDIDATES[@]}"; do
        unit="${candidate%%|*}"
        label="${candidate##*|}"
        
        # Check if the service exists
        if systemctl cat "${unit}.service" &>/dev/null \
            || systemctl cat "${unit}" &>/dev/null; then
            
            st=$(systemctl is-active "${unit}" 2>/dev/null || echo "inactive")
            en=$(systemctl is-enabled "${unit}" 2>/dev/null || echo "disabled")
            
            # Track active, enabled, and installed units
            [[ "$st" == "active" && -z "$au" ]] && { au="$unit"; al="$label"; }
            [[ "$en" == "enabled" && -z "$eu" ]] && { eu="$unit"; el="$label"; }
            [[ -z "$iu" ]] && { iu="$unit"; il="$label"; }
        fi
    done

    # Determine which DM to use (priority: active > enabled > installed)
    if [[ -n "$au" ]]; then
        DM_SERVICE="$au"
        DM_NAME="$al"
        DM_FOUND="true"
        logd "Detected active DM: ${DM_NAME} (${DM_SERVICE})"
    elif [[ -n "$eu" ]]; then
        DM_SERVICE="$eu"
        DM_NAME="$el"
        DM_FOUND="true"
        logd "Detected enabled DM: ${DM_NAME} (${DM_SERVICE})"
    elif [[ -n "$iu" ]]; then
        DM_SERVICE="$iu"
        DM_NAME="$il"
        DM_FOUND="true"
        logd "Detected installed DM: ${DM_NAME} (${DM_SERVICE})"
    else
        DM_SERVICE=""
        DM_NAME="headless-only"
        DM_FOUND="false"
        logd "No display manager detected - headless-only mode"
    fi
}

# Check if display manager is active
dm_is_active() {
    [[ -n "${DM_SERVICE:-}" ]] || return 1
    systemctl is-active --quiet "${DM_SERVICE}" 2>/dev/null
}

# Start display manager
dm_start() {
    [[ -n "${DM_SERVICE:-}" ]] || { logw "No DM to start"; return 1; }
    
    logi "Starting display manager: ${DM_NAME} (${DM_SERVICE})"
    systemctl start "${DM_SERVICE}" 2>/dev/null || true
    
    local i=0
    local max=$(( WAIT_TIMEOUT_S * 2 ))
    while (( i < max )); do
        if dm_is_active; then
            logi "Display manager ${DM_NAME} started successfully"
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    
    logw "Display manager ${DM_NAME} start timed out (may still be coming up)"
    return 1
}

# Stop display manager
dm_stop() {
    [[ -n "${DM_SERVICE:-}" ]] || { logd "No DM to stop"; return 0; }
    
    logi "Stopping display manager: ${DM_NAME} (${DM_SERVICE})"
    systemctl stop "${DM_SERVICE}" 2>/dev/null || true
    
    local i=0
    local max=$(( WAIT_TIMEOUT_S * 2 ))
    while (( i < max )); do
        if ! dm_is_active; then
            logi "Display manager ${DM_NAME} stopped successfully"
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    
    logw "Display manager ${DM_NAME} stop timed out"
    return 1
}

# Get display manager unit name
dm_unit() {
    local svc="${DM_SERVICE:-}"
    [[ "$svc" == *.service ]] && echo "$svc" || echo "${svc}.service"
}
