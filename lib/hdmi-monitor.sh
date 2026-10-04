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
