#!/usr/bin/env bash
# verify-ghost-display.sh - Ghost Display v2 Verification Script
#
# Checks that Ghost Display is properly installed and configured
#
# Usage:
#   sudo ./scripts/verify-ghost-display.sh [options]
#
# Options:
#   --user USERNAME       Check user-specific configuration
#   --connector PORT      HDMI connector to check (default: HDMI-A-1)

set -euo pipefail

CONNECTOR="HDMI-A-1"
TARGET_USER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="$2"; shift 2 ;;
        --connector) CONNECTOR="$2";   shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${BLUE}ℹ${NC} $*"; }
header() { echo -e "\n${BLUE}$*${NC}"; }

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check() {
    if eval "$1" >/dev/null 2>&1; then
        pass "$2"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        fail "$2"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# =============================================================================
# CHECK INSTALLATION
# =============================================================================

header "Ghost Display v2 - Installation Verification"

header "1. Core Files"
check "[[ -f /usr/local/bin/ghost-display.sh ]]" "Main script installed"
check "[[ -f /etc/systemd/system/ghost-display.service ]]" "Systemd service installed"
check "[[ -f /etc/ghost-display/ghost-display.conf ]]" "Configuration file installed"
check "[[ -f /etc/ghost-display/xorg-dummy.conf ]]" "Xorg config installed"
check "[[ -f /usr/local/lib/ghost-display/logging.sh ]]" "Logging module installed"
check "[[ -f /usr/local/lib/ghost-display/config-loader.sh ]]" "Config loader module installed"
check "[[ -f /usr/local/lib/ghost-display/hdmi-monitor.sh ]]" "HDMI monitor module installed"
check "[[ -f /usr/local/lib/ghost-display/x11-virtual.sh ]]" "X11 virtual module installed"
check "[[ -f /usr/local/lib/ghost-display/dm-manager.sh ]]" "DM manager module installed"

header "2. System Configuration"
check "[[ -f /lib/firmware/edid/ghost-display-1920x1080.bin ]]" "EDID firmware installed"
check "grep -q 'dtoverlay=vc4-kms-v3d' /boot/firmware/config.txt" "KMS overlay in config.txt"
check "grep -q 'hdmi_force_hotplug:0=1' /boot/firmware/config.txt" "HDMI force hotplug for port 0"
check "grep -q 'hdmi_force_hotplug:1=1' /boot/firmware/config.txt" "HDMI force hotplug for port 1"
check "grep -q 'drm.edid_firmware' /boot/firmware/cmdline.txt" "EDID firmware in cmdline.txt"
check "grep -q 'video=' /boot/firmware/cmdline.txt" "Video mode in cmdline.txt"

header "3. Required Packages"
check "command -v Xorg" "Xorg installed"
check "dpkg -l | grep -q xserver-xorg-video-dummy" "Dummy Xorg driver installed"

header "4. Service Status"
check "systemctl cat ghost-display.service >/dev/null 2>&1" "Service unit exists"

# Check if service is enabled
if systemctl is-enabled ghost-display.service >/dev/null 2>&1; then
    pass "Service is enabled"
else
    fail "Service is not enabled"
fi

# Check if service is running
if systemctl is-active ghost-display.service >/dev/null 2>&1; then
    pass "Service is running"
else
    warn "Service is not running (may need reboot)"
fi

header "5. Runtime State"
check "[[ -d /run/ghost-display ]]" "Runtime directory exists"
check "[[ -f /run/ghost-display/ghost-display.pid ]]" "PID file exists"
check "[[ -f /run/ghost-display/state ]]" "State file exists"

header "6. HDMI Status"
DRM_ROOT="/sys/class/drm"
HDMI_CONNECTED=false
for f in "${DRM_ROOT}"/card*-HDMI-A-*/status; do
    [[ -f "$f" ]] || continue
    local val
    read -r val < "$f" 2>/dev/null || continue
    if [[ "$val" == "connected" ]]; then
        HDMI_CONNECTED=true
        break
    fi
done

if $HDMI_CONNECTED; then
    pass "HDMI is connected"
else
    warn "HDMI is not connected (expected if no monitor attached)"
fi

header "7. Display Manager"
DM_FOUND=false
for unit in gdm gdm3 sddm lightdm lxdm xdm slim nodm; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1 || systemctl cat "$unit" >/dev/null 2>&1; then
        DM_FOUND=true
        DM_NAME="$unit"
        break
    fi
done

if $DM_FOUND; then
    pass "Display manager detected: $DM_NAME"
    
    # Check if DM is active
    if systemctl is-active "$DM_NAME" >/dev/null 2>&1; then
        pass "Display manager $DM_NAME is active"
    else
        warn "Display manager $DM_NAME is not active"
    fi
else
    warn "No display manager detected (headless-only mode)"
fi

header "8. Virtual Display"
# Check if Xorg is running on the virtual display
VIRTUAL_DISPLAY=":20"
if [[ -f "/tmp/.X${VIRTUAL_DISPLAY#:}-lock" ]]; then
    pass "Virtual display lock file exists (${VIRTUAL_DISPLAY})"
else
    warn "Virtual display lock file not found (${VIRTUAL_DISPLAY})"
fi

# Check for Xorg process
if pgrep -f "Xorg ${VIRTUAL_DISPLAY}" >/dev/null 2>&1; then
    pass "Xorg process running for ${VIRTUAL_DISPLAY}"
else
    warn "Xorg process not found for ${VIRTUAL_DISPLAY}"
fi

header "9. Configuration Check"
CONF_FILE="/etc/ghost-display/ghost-display.conf"
if [[ -f "$CONF_FILE" ]]; then
    pass "Configuration file exists"
    
    # Check for common settings
    check "grep -q '^MODE=' $CONF_FILE" "MODE setting in config"
    check "grep -q '^VIRTUAL_DISPLAY_NUM=' $CONF_FILE" "VIRTUAL_DISPLAY_NUM setting in config"
    check "grep -q '^VIRTUAL_MONITORS=' $CONF_FILE" "VIRTUAL_MONITORS setting in config"
    
    # Show current mode
    CURRENT_MODE=$(grep "^MODE=" "$CONF_FILE" | cut -d= -f2)
    info "Current mode: ${CURRENT_MODE:-combined}"
else
    fail "Configuration file not found"
fi

# =============================================================================
# SUMMARY
# =============================================================================

header ""
header "================================================================"
header " Verification Summary"
header "================================================================"
echo -e "  ${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "  ${RED}Failed: $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}Warnings: $WARN_COUNT${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "\n  ${GREEN}✓ Ghost Display v2 is properly installed!${NC}"
    echo ""
    echo "  To start using Ghost Display:"
    echo "    1. If not already running: sudo systemctl start ghost-display.service"
    echo "    2. Check logs: sudo journalctl -u ghost-display.service -f"
    echo "    3. For RustDesk: DISPLAY=:20 rustdesk"
    echo ""
    exit 0
else
    echo -e "\n  ${RED}✗ Some checks failed. Please review the output above.${NC}"
    echo ""
    exit 1
fi
