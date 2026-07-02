#!/usr/bin/env bash
# lib/vnc-manager.sh - VNC management for Ghost Display
# Based on VNC functions from hdmi-switch.sh

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh

# =============================================================================
# VNC MANAGEMENT
# =============================================================================

# Start x11vnc
vnc_start() {
    # Check if x11vnc is installed
    if ! command -v x11vnc &>/dev/null; then
        logw "x11vnc not installed - skipping VNC start"
        return 0
    fi
    
    # Ensure log directory exists
    mkdir -p "$XORG_LOG_DIR" 2>/dev/null || true
    
    logi "Starting x11vnc on ${VIRTUAL_DISPLAY} port ${VNC_PORT}"
    
    # FIX B5 from AlwaysX11: use -pidfile so we get the real x11vnc PID
    local args=(
        -display "${VIRTUAL_DISPLAY}"
        -port "${VNC_PORT}"
        -forever
        -shared
        -noxdamage
        -quiet
        -o "${XORG_LOG_DIR}/x11vnc.log"
        -pidfile "${VNC_PID_FILE}"
    )
    
    # Add password file if it exists
    if [[ -f "${VNC_PASSWD_FILE}" ]]; then
        args+=(-rfbauth "${VNC_PASSWD_FILE}")
    else
        args+=(-nopw)
        logw "No VNC password file at ${VNC_PASSWD_FILE} - using no password"
    fi
    
    # Start x11vnc
    DISPLAY="${VIRTUAL_DISPLAY}" x11vnc "${args[@]}" &>/dev/null &
    
    # Wait for PID file to be created
    sleep 0.5
    
    if [[ -f "$VNC_PID_FILE" ]]; then
        logd "x11vnc running PID=$(cat "$VNC_PID_FILE")"
    else
        logw "x11vnc did not write PID file"
    fi
    
    return 0
}

# Stop x11vnc
vnc_stop() {
    # Stop using PID file
    if [[ -f "$VNC_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VNC_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
        rm -f "$VNC_PID_FILE"
    fi
    
    # Also kill any x11vnc processes for this display
    pkill -f "x11vnc.*${VIRTUAL_DISPLAY}" 2>/dev/null || true
    
    logd "x11vnc stopped"
    return 0
}

# Check if VNC is running
vnc_is_running() {
    [[ -f "$VNC_PID_FILE" ]] || return 1
    local pid
    pid=$(cat "$VNC_PID_FILE" 2>/dev/null || echo "")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
