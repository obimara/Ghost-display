#!/usr/bin/env bash
# install-ghost-display.sh - Ghost Display v2 Installer
#
# Unified installer for Ghost Display (merges AlwaysX11 and Ghost-display-x11)
#
# What this installer does:
#   1. Installs required packages (xserver-xorg-video-dummy, optionally x11vnc)
#   2. Injects synthetic EDID so the Pi always advertises a display
#   3. Patches /boot/firmware/config.txt (vc4-kms-v3d, hdmi_force_hotplug)
#   4. Patches /boot/firmware/cmdline.txt (drm.edid_firmware, video=)
#   5. Disables Wayland for GDM (falls back to X11)
#   6. Installs Ghost Display scripts, configs, and systemd unit
#   7. Enables and starts ghost-display.service
#
# Usage:
#   sudo ./scripts/install-ghost-display.sh --user USERNAME [options]
#   sudo ./scripts/install-ghost-display.sh --rollback
#
# Options:
#   --user       USERNAME   (required) desktop user account
#   --connector  PORT       HDMI connector name (default: HDMI-A-1)
#   --mode       WxH@Hz     virtual display mode (default: 1920x1080@60)
#   --vnc                   enable x11vnc in headless mode
#   --rollback              undo a previous installation

set -euo pipefail

# =============================================================================
# DEFAULT VALUES
# =============================================================================

CONNECTOR="HDMI-A-1"
MODE="1920x1080@60"
TARGET_USER=""
ROLLBACK=false
ENABLE_VNC=false

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDID_HEX="$REPO_ROOT/assets/edid/alwaysx11-1920x1080.hex"
EDID_BIN="/lib/firmware/edid/ghost-display-1920x1080.bin"
CMDLINE="/boot/firmware/cmdline.txt"
CONFIG="/boot/firmware/config.txt"
BACKUP_DIR="/var/lib/ghost-display/backups"
INST_DIR="/etc/ghost-display"
LIB_DIR="/usr/local/lib/ghost-display"
BIN_DIR="/usr/local/bin"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log()   { echo "[ghost-display] $*"; }
warn()  { echo "[ghost-display] WARN: $*" >&2; }
die()   { echo "[ghost-display] ERROR: $*" >&2; exit 1; }

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="$2"; shift 2 ;;
        --connector) CONNECTOR="$2";   shift 2 ;;
        --mode)      MODE="$2";        shift 2 ;;
        --vnc)       ENABLE_VNC=true;  shift   ;;
        --rollback)  ROLLBACK=true;    shift   ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# =============================================================================
# ROOT CHECK
# =============================================================================

[[ "$EUID" -eq 0 ]] || die "Must run as root (sudo ./scripts/install-ghost-display.sh ...)"

# =============================================================================
# ROLLBACK
# =============================================================================

if $ROLLBACK; then
    log "Rolling back Ghost Display installation..."
    
    # Restore backed up files
    for f in cmdline.txt config.txt; do
        bak="$BACKUP_DIR/$f.bak"
        dest="/boot/firmware/$f"
        if [[ -f "$bak" ]]; then
            cp "$bak" "$dest"
            log "  Restored $dest"
        fi
    done
    
    # Disable and remove service
    systemctl disable --now ghost-display.service 2>/dev/null || true
    rm -f /etc/systemd/system/ghost-display.service \
          /etc/systemd/system/hdmi-watch.service \
          /usr/local/bin/ghost-display.sh \
          /usr/local/bin/hdmi-switch.sh \
          "$EDID_BIN"
    
    # Remove config and lib directories
    rm -rf "$INST_DIR" "$LIB_DIR"
    
    # Reload systemd
    systemctl daemon-reload
    
    log "Rollback complete. Please reboot: sudo reboot"
    exit 0
fi

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

[[ -n "$TARGET_USER" ]] || die "--user <username> is required"
id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' not found"
[[ -f "$EDID_HEX" ]] || die "EDID hex not found: $EDID_HEX"
[[ -f "$CMDLINE" ]] || die "Not a Pi 5 system? $CMDLINE missing"
[[ -f "$CONFIG" ]] || die "Not a Pi 5 system? $CONFIG missing"

log "Installing Ghost Display v2"
log "  User:      $TARGET_USER"
log "  Connector: $CONNECTOR"
log "  Mode:      $MODE"
$ENABLE_VNC && log "  VNC:       enabled"

# =============================================================================
# BACKUP
# =============================================================================

log "Creating backups..."
mkdir -p "$BACKUP_DIR"

for f in cmdline.txt config.txt; do
    src="/boot/firmware/$f"
    bak="$BACKUP_DIR/$f.bak"
    if [[ ! -f "$bak" ]]; then
        cp "$src" "$bak"
        log "  Backed up $src -> $bak"
    else
        log "  Backup already exists: $bak (not overwriting)"
    fi
done

# =============================================================================
# INSTALL PACKAGES
# =============================================================================

log "Installing required packages..."

# Install dummy Xorg driver
apt-get install -y xserver-xorg-video-dummy

# Install x11vnc if requested
if $ENABLE_VNC; then
    log "Installing x11vnc..."
    apt-get install -y x11vnc
fi

# =============================================================================
# INSTALL EDID FIRMWARE
# =============================================================================

log "Installing EDID firmware blob..."
mkdir -p "$(dirname "$EDID_BIN")"
xxd -r -p "$EDID_HEX" > "$EDID_BIN"
log "  EDID: $EDID_BIN"

# =============================================================================
# PATCH config.txt
# =============================================================================

log "Patching /boot/firmware/config.txt..."

# Upgrade fkms -> kms if present (Pi 5 requires kms)
if grep -q "dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
    sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$CONFIG"
    log "  Upgraded fkms -> kms"
fi

# Add required overlays and settings
grep -q "dtoverlay=vc4-kms-v3d" "$CONFIG" || echo "dtoverlay=vc4-kms-v3d" >> "$CONFIG"
grep -q "hdmi_force_hotplug:0=1" "$CONFIG" || echo "hdmi_force_hotplug:0=1" >> "$CONFIG"
grep -q "hdmi_force_hotplug:1=1" "$CONFIG" || echo "hdmi_force_hotplug:1=1" >> "$CONFIG"
grep -q "max_framebuffers=2" "$CONFIG" || echo "max_framebuffers=2" >> "$CONFIG"

log "  config.txt patched successfully"

# =============================================================================
# PATCH cmdline.txt
# =============================================================================

log "Patching /boot/firmware/cmdline.txt..."

EDID_PARAM="drm.edid_firmware=${CONNECTOR}:edid/ghost-display-1920x1080.bin"
VIDEO_PARAM="video=${CONNECTOR}:${MODE}e"

for param in "$EDID_PARAM" "$VIDEO_PARAM"; do
    if ! grep -qF "$param" "$CMDLINE"; then
        sed -i "s|$| $param|" "$CMDLINE"
        log "  Added: $param"
    else
        log "  Already present: $param"
    fi
done

# Normalize cmdline.txt
sed -i 's/[[:space:]]*$//' "$CMDLINE"
echo >> "$CMDLINE"

log "  cmdline.txt patched successfully"

# =============================================================================
# DM-SPECIFIC CONFIGURATION
# =============================================================================

log "Configuring display managers..."

# Detect which DM is installed
DETECTED_DM=""
for unit in gdm gdm3; do
    if systemctl cat "${unit}.service" &>/dev/null || systemctl cat "$unit" &>/dev/null; then
        DETECTED_DM="$unit"
        break
    fi
done

# GDM: disable Wayland so it falls back to X11
if [[ -n "$DETECTED_DM" ]]; then
    for gdm_conf in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
        [[ -f "$gdm_conf" ]] || continue
        if grep -q "WaylandEnable=true" "$gdm_conf"; then
            sed -i 's/WaylandEnable=true/WaylandEnable=false/' "$gdm_conf"
            log "  GDM: disabled Wayland in $gdm_conf"
        elif ! grep -q "WaylandEnable" "$gdm_conf"; then
            sed -i '/\[daemon\]/a WaylandEnable=false' "$gdm_conf"
            log "  GDM: added WaylandEnable=false to $gdm_conf"
        else
            log "  GDM: WaylandEnable already correct in $gdm_conf"
        fi
    done
else
    log "  No GDM detected - skipping Wayland-disable step"
fi

# SDDM: ensure X11 session backend
if systemctl cat sddm.service &>/dev/null || systemctl cat sddm &>/dev/null; then
    mkdir -p /etc/sddm.conf.d
    if [[ ! -f /etc/sddm.conf.d/ghost-display.conf ]]; then
        cat > /etc/sddm.conf.d/ghost-display.conf << 'SDDM'
# Ghost Display - force SDDM to use X11 display server
[General]
DisplayServer=x11
SDDM
        log "  SDDM: created /etc/sddm.conf.d/ghost-display.conf (force X11)"
    fi
fi

# =============================================================================
# INSTALL GHOST DISPLAY FILES
# =============================================================================

log "Installing Ghost Display files..."

# Create directories
mkdir -p "$INST_DIR" "$LIB_DIR" "$XORG_LOG_DIR" "$RUN_DIR"

# Install library modules
for lib_file in "${REPO_ROOT}/lib/"*.sh; do
    if [[ -f "$lib_file" ]]; then
        install -Dm755 "$lib_file" "$LIB_DIR/$(basename "$lib_file")"
        log "  Installed: $(basename "$lib_file")"
    fi
done

# Install main script
install -Dm755 "${REPO_ROOT}/ghost-display.sh" "${BIN_DIR}/ghost-display.sh"
log "  Installed: ghost-display.sh"

# Install configuration
if [[ ! -f "$INST_DIR/ghost-display.conf" ]]; then
    install -Dm644 "${REPO_ROOT}/config/ghost-display.conf" "$INST_DIR/ghost-display.conf"
    
    # Enable VNC if requested
    if $ENABLE_VNC; then
        sed -i "s/^VNC_ENABLE=false/VNC_ENABLE=true/" "$INST_DIR/ghost-display.conf"
    fi
    
    log "  Installed: ghost-display.conf"
else
    log "  $INST_DIR/ghost-display.conf already exists - not overwriting"
fi

# Install Xorg config
install -Dm644 "${REPO_ROOT}/x11/ghost-display.conf" "$INST_DIR/xorg-dummy.conf"
log "  Installed: xorg-dummy.conf"

# Install systemd service
install -Dm644 "${REPO_ROOT}/systemd/ghost-display.service" /etc/systemd/system/ghost-display.service
log "  Installed: ghost-display.service"

# =============================================================================
# ENABLE SERVICE
# =============================================================================

log "Enabling ghost-display.service..."
systemctl daemon-reload
systemctl enable ghost-display.service

# Don't start yet - user needs to reboot for EDID/cmdline changes to take effect
log "Service enabled (will start on next boot)"

# =============================================================================
# COMPLETION
# =============================================================================

log ""
log "================================================================"
log " Ghost Display v2 installation complete!"
log "================================================================"
log ""
log " Next steps:"
log "   1. Reboot:  sudo reboot"
log "   2. Verify:  sudo journalctl -u ghost-display.service -f"
log "   3. Config:  sudo nano $INST_DIR/ghost-display.conf"
log "   4. Status:  sudo systemctl status ghost-display.service"
log "   5. Undo:    sudo ./scripts/install-ghost-display.sh --rollback"
log ""
log " For RustDesk:"
log "   Start RustDesk with: DISPLAY=:20 rustdesk"
log "   (or whatever VIRTUAL_DISPLAY_NUM you configured)"
log "================================================================"
