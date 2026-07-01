#!/usr/bin/env bash
# lib/state-manager.sh - State management and locking for Ghost Display
# Provides atomic locking and state tracking

set -euo pipefail

# Dependencies: logging.sh, config-loader.sh

# =============================================================================
# LOCKING
# =============================================================================

# Initialize locking
# Uses file descriptor 9 for the lock file (FIX B2 from AlwaysX11)
LOCK_FD=9

init_locking() {
    # Ensure RUN_DIR exists
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    
    # Open lock file for atomic locking
    eval "exec $LOCK_FD>\"$LOCK_FILE\""
    
    # Try to acquire lock
    if ! flock -n $LOCK_FD 2>/dev/null; then
        local existing_pid
        existing_pid=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
        loge "Ghost Display is already running (PID ${existing_pid}) - exiting."
        exit 1
    fi
    
    # Write our PID
    echo $$ > "$PID_FILE"
    logd "Lock acquired, PID $$ written to ${PID_FILE}"
}

# Cleanup on exit
cleanup() {
    logi "Ghost Display shutting down"
    
    # Stop all services
    if [[ "$MODE" == "virtual" || "$MODE" == "combined" ]]; then
        virtual_stop
    fi
    
    if [[ "$MODE" == "hotplug" || "$MODE" == "combined" ]]; then
        # If we were in display mode, stop DM
        if [[ "$(state_get)" == "display" ]]; then
            dm_stop 2>/dev/null || true
        fi
    fi
    
    # Remove PID and state files
    rm -f "$PID_FILE" "$STATE_FILE" "$LOCK_FILE"
    
    logi "Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT SIGHUP

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Set current state
state_set() {
    echo "$1" > "$STATE_FILE"
    logd "State changed to: $1"
}

# Get current state
state_get() {
    cat "$STATE_FILE" 2>/dev/null || echo "unknown"
}

# Initialize state
state_init() {
    # Determine initial state based on mode and HDMI status
    if [[ "$MODE" == "virtual" ]]; then
        state_set "virtual"
    elif [[ "$MODE" == "hotplug" ]]; then
        if hdmi_connected; then
            state_set "display"
        else
            state_set "headless"
        fi
    elif [[ "$MODE" == "combined" ]]; then
        # In combined mode, virtual display is always available
        # But we also track HDMI state
        if hdmi_connected; then
            state_set "combined_display"
        else
            state_set "combined_headless"
        fi
    fi
}

# Check if state transition is needed
state_needs_transition() {
    local current_state="$(state_get)"
    local target_state="$1"
    
    [[ "$current_state" == "$target_state" ]] && return 1
    return 0
}
