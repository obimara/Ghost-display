#!/usr/bin/env bash
# lib/config-loader.sh - Unified configuration loader for Ghost Display
# Source this file to load configuration from multiple sources:
# 1. Default values
# 2. Configuration file (/etc/ghost-display/ghost-display.conf)
# 3. Environment variables (GHOST_* and ALWAYSX11_* for backward compatibility)

set -euo pipefail

# =============================================================================
# DEFAULT VALUES
# =============================================================================

# Mode: virtual, hotplug, or combined
MODE="${GHOST_MODE:-${ALWAYSX11_MODE:-combined}}"

# ===== Virtual Display Settings =====
VIRTUAL_DISPLAY_NUM="${GHOST_DISPLAY_NUM:-${ALWAYSX11_DUMMY_DISPLAY:-20}}"
VIRTUAL_DISPLAY=":${VIRTUAL_DISPLAY_NUM}"
VIRTUAL_MONITORS="${GHOST_MONITORS:-2}"
VIRTUAL_RESOLUTION="${GHOST_RESOLUTION:-${GHOST_WIDTH:-1920}x${GHOST_HEIGHT:-1080}}"
VIRTUAL_SCALE="${GHOST_SCALE:-1.0}"
VIRTUAL_DPI="${GHOST_DPI:-96}"
VIRTUAL_LAYOUT="${GHOST_LAYOUT:-horizontal}"
VIRTUAL_NAME_PREFIX="${GHOST_NAME_PREFIX:-Ghost}"
VIRTUAL_MONITOR_SPECS="${GHOST_MONITOR_SPECS:-}"
VIRTUAL_MAX_WIDTH="${GHOST_MAX_WIDTH:-8192}"
VIRTUAL_MAX_HEIGHT="${GHOST_MAX_HEIGHT:-8192}"

# ===== HDMI Hotplug Settings =====
HDMI_POLL_INTERVAL="${POLL_INTERVAL:-1}"
HDMI_STABLE_SECONDS="${STABLE_SECONDS:-5}"
HDMI_DRM_ROOT="${DRM_ROOT:-/sys/class/drm}"

# ===== Display Manager Settings =====
DM_SERVICE="${DM_SERVICE:-}"
DM_LIB="${DM_LIB:-/usr/local/lib/ghost-display/dm-detect.sh}"

# ===== Xorg Settings =====
XORG_BIN="${XORG_BIN:-/usr/bin/Xorg}"
DUMMY_XORG_CONF="${DUMMY_XORG_CONF:-/etc/ghost-display/xorg-dummy.conf}"
XORG_LOG_DIR="${XORG_LOG_DIR:-/var/log/ghost-display}"

# ===== VNC Settings =====
VNC_ENABLE="${VNC_ENABLE:-false}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWD_FILE="${VNC_PASSWD_FILE:-/etc/ghost-display/vncpasswd}"

# ===== Runtime Settings =====
RUN_DIR="${RUN_DIR:-/run/ghost-display}"
CONF_FILE="${CONF_FILE:-/etc/ghost-display/ghost-display.conf}"
PID_FILE="${PID_FILE:-${RUN_DIR}/ghost-display.pid}"
LOCK_FILE="${LOCK_FILE:-${RUN_DIR}/ghost-display.lock}"
STATE_FILE="${STATE_FILE:-${RUN_DIR}/state}"
DUMMY_PID_FILE="${DUMMY_PID_FILE:-${RUN_DIR}/xorg-dummy.pid}"
VNC_PID_FILE="${VNC_PID_FILE:-${RUN_DIR}/x11vnc.pid}"

# ===== Logging Settings =====
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
LOG_TAG="ghost-display"

# ===== Timeout Settings =====
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-15}"

# ===== RustDesk Optimization =====
RUSTDESK_OPTIMIZED="${RUSTDESK_OPTIMIZED:-true}"

# =============================================================================
# LOAD CONFIGURATION FILE
# =============================================================================
load_config() {
    # Create directories if they don't exist
    mkdir -p "$RUN_DIR" "$XORG_LOG_DIR" "$(dirname "$CONF_FILE")" 2>/dev/null || true
    
    # Load config file if it exists
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi
    
    # Also check for old AlwaysX11 config for backward compatibility
    local OLD_CONF="/etc/alwaysx11/alwaysx11.conf"
    if [[ -f "$OLD_CONF" ]] && [[ ! -f "$CONF_FILE" ]]; then
        logw "Found old AlwaysX11 config at $OLD_CONF, migrating to $CONF_FILE"
        mkdir -p "$(dirname "$CONF_FILE")"
        cp "$OLD_CONF" "$CONF_FILE"
        # Convert old variable names to new ones
        sed -i 's/^DUMMY_DISPLAY=/VIRTUAL_DISPLAY=/g' "$CONF_FILE"
        sed -i 's/^DUMMY_XORG_CONF=/XORG_DUMMY_CONF=/g' "$CONF_FILE"
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi
    
    # Apply environment variable overrides (GHOST_* takes precedence)
    # Virtual display
    VIRTUAL_DISPLAY_NUM="${GHOST_DISPLAY_NUM:-$VIRTUAL_DISPLAY_NUM}"
    VIRTUAL_DISPLAY=":${VIRTUAL_DISPLAY_NUM}"
    VIRTUAL_MONITORS="${GHOST_MONITORS:-$VIRTUAL_MONITORS}"
    VIRTUAL_RESOLUTION="${GHOST_RESOLUTION:-$VIRTUAL_RESOLUTION}"
    VIRTUAL_SCALE="${GHOST_SCALE:-$VIRTUAL_SCALE}"
    VIRTUAL_DPI="${GHOST_DPI:-$VIRTUAL_DPI}"
    VIRTUAL_LAYOUT="${GHOST_LAYOUT:-$VIRTUAL_LAYOUT}"
    VIRTUAL_NAME_PREFIX="${GHOST_NAME_PREFIX:-$VIRTUAL_NAME_PREFIX}"
    VIRTUAL_MONITOR_SPECS="${GHOST_MONITOR_SPECS:-$VIRTUAL_MONITOR_SPECS}"
    
    # HDMI hotplug
    HDMI_POLL_INTERVAL="${POLL_INTERVAL:-$HDMI_POLL_INTERVAL}"
    HDMI_STABLE_SECONDS="${STABLE_SECONDS:-$HDMI_STABLE_SECONDS}"
    HDMI_DRM_ROOT="${DRM_ROOT:-$HDMI_DRM_ROOT}"
    
    # Mode can be overridden
    MODE="${GHOST_MODE:-$MODE}"
    
    # Ensure VIRTUAL_DISPLAY is properly formatted
    if [[ "$VIRTUAL_DISPLAY" != :* ]]; then
        VIRTUAL_DISPLAY=":${VIRTUAL_DISPLAY}"
    fi
}

# =============================================================================
# VALIDATION
# =============================================================================
validate_config() {
    # Validate mode
    if [[ "$MODE" != "virtual" && "$MODE" != "hotplug" && "$MODE" != "combined" ]]; then
        loge "Invalid MODE: '$MODE'. Must be 'virtual', 'hotplug', or 'combined'."
        exit 1
    fi
    
    # Validate numbers
    if ! [[ "$HDMI_POLL_INTERVAL" =~ ^[0-9]+$ ]]; then
        loge "POLL_INTERVAL must be a positive integer: '$HDMI_POLL_INTERVAL'"
        exit 1
    fi
    
    if ! [[ "$HDMI_STABLE_SECONDS" =~ ^[0-9]+$ ]]; then
        loge "STABLE_SECONDS must be a positive integer: '$HDMI_STABLE_SECONDS'"
        exit 1
    fi
    
    # Validate virtual display settings if in virtual or combined mode
    if [[ "$MODE" == "virtual" || "$MODE" == "combined" ]]; then
        if ! [[ "$VIRTUAL_DISPLAY_NUM" =~ ^[0-9]+$ ]]; then
            loge "VIRTUAL_DISPLAY_NUM must be a positive integer: '$VIRTUAL_DISPLAY_NUM'"
            exit 1
        fi
        
        if ! [[ "$VIRTUAL_MONITORS" =~ ^[0-9]+$ ]]; then
            loge "VIRTUAL_MONITORS must be a positive integer: '$VIRTUAL_MONITORS'"
            exit 1
        fi
    fi
}
