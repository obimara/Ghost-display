#!/usr/bin/env bash
# ghost-display.sh - Ghost Display v2
# Unified HDMI hotplug watcher and virtual X11 display manager
# 
# Modes:
#   virtual   - Pure virtual display (for RustDesk, no HDMI monitoring)
#   hotplug   - HDMI hotplug monitoring only (like AlwaysX11)
#   combined  - Both virtual display + HDMI monitoring (default)
#
# Usage:
#   ghost-display [OPTIONS]
#
# Options:
#   --mode MODE          virtual, hotplug, or combined (default: combined)
#   --dry-run            Show configuration without starting
#   --foreground         Run in foreground (for debugging)
#   --rollback           Remove Ghost Display installation
#   -h, --help           Show this help
#
# Environment variables (can also be set in /etc/ghost-display/ghost-display.conf):
#   MODE                    virtual, hotplug, or combined
#   VIRTUAL_DISPLAY_NUM     Display number for virtual X11 (default: 20)
#   VIRTUAL_MONITORS        Number of virtual monitors (default: 2)
#   VIRTUAL_RESOLUTION      Resolution for virtual monitors (default: 1920x1080)
#   VIRTUAL_SCALE           Scaling factor (default: 1.0)
#   VIRTUAL_DPI             DPI for virtual display (default: 96)
#   VIRTUAL_LAYOUT          Monitor layout: horizontal or vertical (default: horizontal)
#   VIRTUAL_NAME_PREFIX     Prefix for monitor names (default: Ghost)
#   VIRTUAL_MONITOR_SPECS   Comma-separated monitor specs (e.g., "1920x1080@1,2560x1440@1.25")
#   HDMI_POLL_INTERVAL      Seconds between HDMI polls (default: 1)
#   HDMI_STABLE_SECONDS     Stable ticks before switching (default: 5)
#   DM_SERVICE              Force specific display manager
#   VNC_ENABLE              Enable VNC in headless mode (default: false)
#   VNC_PORT                VNC port (default: 5900)
#   LOG_LEVEL               debug, info, warn, error (default: info)
#
# Examples:
#   # Start in combined mode (default)
#   sudo ghost-display
#
#   # Start pure virtual display for RustDesk
#   sudo ghost-display --mode virtual
#
#   # Start HDMI hotplug monitoring only
#   sudo ghost-display --mode hotplug
#
#   # Show configuration without starting
#   sudo ghost-display --dry-run
#
#   # Run in foreground for debugging
#   sudo ghost-display --foreground

set -euo pipefail

# =============================================================================
# SOURCE LIBRARY MODULES
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${REPO_ROOT}/lib"

# Source all library modules
for lib_file in "${LIB_DIR}"/*.sh; do
    if [[ -f "$lib_file" ]]; then
        # shellcheck source=/dev/null
        source "$lib_file"
    fi
done

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DRY_RUN=false
FOREGROUND=false
ROLLBACK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --foreground)
            FOREGROUND=true
            shift
            ;;
        --rollback)
            ROLLBACK=true
            shift
            ;;
        -h|--help)
            grep '^# ' "$0" | sed 's/^# //; s/^//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# ROLLBACK
# =============================================================================

if $ROLLBACK; then
    logi "Rolling back Ghost Display installation..."
    
    # Use the installer's rollback functionality
    if [[ -f "${REPO_ROOT}/scripts/install-alwaysx11.sh" ]]; then
        bash "${REPO_ROOT}/scripts/install-alwaysx11.sh" --rollback
    else
        loge "Installer not found for rollback"
        exit 1
    fi
    exit 0
fi

# =============================================================================
# INITIALIZATION
# =============================================================================

# Load configuration
load_config

# Validate configuration
validate_config

# Initialize logging (already done by logging.sh)

# Initialize locking
init_locking

# Detect display manager
dm_detect

# Log startup information
logi "========================================"
logi "Ghost Display v2 Starting"
logi "  Mode: ${MODE}"
logi "  DM: ${DM_NAME} (service: ${DM_SERVICE:-none})"
logi "  Virtual Display: ${VIRTUAL_DISPLAY}"
logi "  HDMI Poll: ${HDMI_POLL_INTERVAL}s | Stable: ${HDMI_STABLE_SECONDS} ticks"
logi "  VNC: ${VNC_ENABLE}"
logi "  RustDesk Optimized: ${RUSTDESK_OPTIMIZED}"
logi "========================================"

# =============================================================================
# DRY RUN MODE
# =============================================================================

if $DRY_RUN; then
    logi "Dry run mode - showing configuration without starting"
    
    if [[ "$MODE" == "virtual" || "$MODE" == "combined" ]]; then
        if build_monitor_specs; then
            print_virtual_plan
        else
            loge "Failed to build monitor specifications"
            exit 1
        fi
    fi
    
    if [[ "$MODE" == "hotplug" || "$MODE" == "combined" ]]; then
        logi "HDMI Hotplug Configuration:"
        logi "  Poll Interval: ${HDMI_POLL_INTERVAL}s"
        logi "  Stable Seconds: ${HDMI_STABLE_SECONDS}"
        logi "  DRM Root: ${HDMI_DRM_ROOT}"
        
        if hdmi_connected; then
            logi "  Current HDMI State: CONNECTED"
        else
            logi "  Current HDMI State: DISCONNECTED"
        fi
    fi
    
    logi "Display Manager: ${DM_NAME} (${DM_SERVICE:-none})"
    
    exit 0
fi

# =============================================================================
# INITIAL STATE SETUP
# =============================================================================

# Initialize state
state_init

# Build monitor specs if in virtual or combined mode
if [[ "$MODE" == "virtual" || "$MODE" == "combined" ]]; then
    if ! build_monitor_specs; then
        loge "Failed to build monitor specifications"
        exit 1
    fi
    print_virtual_plan
fi

# =============================================================================
# START SERVICES BASED ON MODE
# =============================================================================

start_services() {
    if [[ "$MODE" == "virtual" ]]; then
        # Pure virtual mode - just start virtual display
        logi "Starting in VIRTUAL mode"
        if ! virtual_start; then
            loge "Failed to start virtual display"
            exit 1
        fi
        state_set "virtual"
        
        # Start VNC if enabled
        if [[ "$VNC_ENABLE" == "true" ]]; then
            vnc_start
        fi
        
    elif [[ "$MODE" == "hotplug" ]]; then
        # HDMI hotplug mode - like AlwaysX11
        logi "Starting in HOTPLUG mode"
        
        # Determine initial state based on HDMI
        if hdmi_connected; then
            logi "HDMI connected at startup - starting display manager"
            if [[ "$DM_FOUND" == "true" ]]; then
                dm_start || logw "Display manager start timed out"
            else
                logi "No display manager installed - headless mode only"
            fi
            state_set "display"
        else
            logi "No HDMI at startup - starting dummy Xorg"
            # Start dummy Xorg for headless mode
            if ! virtual_start; then
                loge "Failed to start dummy Xorg"
                exit 1
            fi
            state_set "headless"
            
            # Start VNC if enabled
            if [[ "$VNC_ENABLE" == "true" ]]; then
                vnc_start
            fi
        fi
        
    elif [[ "$MODE" == "combined" ]]; then
        # Combined mode - virtual display always on, plus HDMI monitoring
        logi "Starting in COMBINED mode"
        
        # Always start virtual display
        if ! virtual_start; then
            loge "Failed to start virtual display"
            exit 1
        fi
        
        # Start VNC if enabled
        if [[ "$VNC_ENABLE" == "true" ]]; then
            vnc_start
        fi
        
        # Check HDMI state and start DM if connected
        if hdmi_connected; then
            logi "HDMI connected - starting display manager"
            if [[ "$DM_FOUND" == "true" ]]; then
                dm_start || logw "Display manager start timed out"
            fi
            state_set "combined_display"
        else
            logi "No HDMI connected - display manager not started"
            state_set "combined_headless"
        fi
    fi
    
    logi "Ghost Display started successfully in ${MODE} mode"
}

# =============================================================================
# MAIN LOOP FOR HOTPLUG MODES
# =============================================================================

run_hotplug_loop() {
    local stable_count=0
    local last_target=""
    
    while true; do
        # Check HDMI state
        local target
        if hdmi_connected; then
            target="display"
        else
            target="headless"
        fi
        
        # Debouncing logic (FIX B9 from AlwaysX11)
        if [[ "$target" != "$last_target" ]]; then
            stable_count=0
            last_target="$target"
            logd "HDMI change detected -> target=${target} (need ${HDMI_STABLE_SECONDS} stable ticks)"
        else
            stable_count=$((stable_count + 1))
        fi
        
        # Check if we need to switch
        if (( stable_count >= HDMI_STABLE_SECONDS )); then
            local current="$(state_get)"
            local need_switch=false
            
            if [[ "$target" == "display" && "$current" != "display" && "$current" != "combined_display" ]]; then
                need_switch=true
            elif [[ "$target" == "headless" && "$current" != "headless" && "$current" != "combined_headless" ]]; then
                need_switch=true
            fi
            
            if $need_switch; then
                logi "Stable ${HDMI_STABLE_SECONDS} ticks -> ${current} -> ${target}"
                
                if [[ "$target" == "display" ]]; then
                    # Switch to display mode
                    if [[ "$MODE" == "hotplug" ]]; then
                        # Stop dummy Xorg
                        virtual_stop
                        # Start display manager
                        if [[ "$DM_FOUND" == "true" ]]; then
                            dm_start && logi "DM '${DM_NAME}' started" \
                                     || logw "DM '${DM_NAME}' start timed out"
                        else
                            logi "No DM installed - cannot switch to display mode"
                        fi
                        state_set "display"
                    elif [[ "$MODE" == "combined" ]]; then
                        # In combined mode, virtual display stays on
                        # Just start DM if not already running
                        if [[ "$DM_FOUND" == "true" ]] && ! dm_is_active; then
                            dm_start && logi "DM '${DM_NAME}' started" \
                                     || logw "DM '${DM_NAME}' start timed out"
                        fi
                        state_set "combined_display"
                    fi
                    
                elif [[ "$target" == "headless" ]]; then
                    # Switch to headless mode
                    if [[ "$MODE" == "hotplug" ]]; then
                        # Stop display manager
                        if [[ "$DM_FOUND" == "true" ]] && dm_is_active; then
                            dm_stop && logi "DM '${DM_NAME}' stopped" \
                                     || logw "DM stop timed out"
                        fi
                        # Start dummy Xorg
                        if ! virtual_start; then
                            loge "Failed to start dummy Xorg"
                            state_set "headless_error"
                        else
                            state_set "headless"
                        fi
                    elif [[ "$MODE" == "combined" ]]; then
                        # In combined mode, virtual display stays on
                        # Just stop DM if running
                        if [[ "$DM_FOUND" == "true" ]] && dm_is_active; then
                            dm_stop && logi "DM '${DM_NAME}' stopped" \
                                     || logw "DM stop timed out"
                        fi
                        state_set "combined_headless"
                    fi
                fi
                
                stable_count=0
            fi
        fi
        
        # Watchdog: resurrect dead Xorg in hotplug mode
        if [[ "$MODE" == "hotplug" ]] && [[ "$(state_get)" == "headless" ]] && ! virtual_is_running; then
            logw "Dummy Xorg died unexpectedly - restarting"
            if ! virtual_start; then
                loge "Watchdog restart failed"
                state_set "headless_error"
            fi
        fi
        
        # Watchdog: resurrect dead virtual display in combined mode
        if [[ "$MODE" == "combined" ]] && ! virtual_is_running; then
            logw "Virtual display died unexpectedly - restarting"
            if ! virtual_start; then
                loge "Watchdog restart failed"
            fi
        fi
        
        sleep "$HDMI_POLL_INTERVAL"
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Start services
start_services

# Run main loop if in hotplug or combined mode
if [[ "$MODE" == "hotplug" || "$MODE" == "combined" ]]; then
    if $FOREGROUND; then
        logi "Running in foreground (press Ctrl+C to stop)"
        run_hotplug_loop
    else
        logi "Running in background (use journalctl to view logs)"
        run_hotplug_loop
    fi
elif [[ "$MODE" == "virtual" ]]; then
    if $FOREGROUND; then
        logi "Virtual display running in foreground (press Ctrl+C to stop)"
        # Keep running until interrupted
        while true; do
            sleep 60
        done
    else
        logi "Virtual display running in background"
        # Keep running until interrupted
        while true; do
            sleep 60
        done
    fi
fi
