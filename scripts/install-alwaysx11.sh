#!/usr/bin/env bash
# install-alwaysx11.sh — AlwaysX11 installer for Raspberry Pi 5 / Debian Trixie
#
# Desktop-manager agnostic: works with GDM, SDDM, LightDM, LXDM, XDM,
# SLiM, nodm, or pure headless (no DM at all).
#
# What this installer does:
#   1. Installs xserver-xorg-video-dummy package
#   2. Injects a synthetic EDID so the Pi always advertises a display
#   3. Patches /boot/firmware/config.txt  (vc4-kms-v3d, hdmi_force_hotplug)
#   4. Patches /boot/firmware/cmdline.txt (drm.edid_firmware, video=)
#   5. If GDM is detected, disables Wayland so GDM falls back to X11
#      (no-op for SDDM/LightDM/others which are X11-only)
#   6. Installs AlwaysX11 scripts, configs, and systemd unit
#   7. Enables and starts hdmi-watch.service
#
# Usage:
#   sudo ./scripts/install-alwaysx11.sh --user USERNAME [options]
#   sudo ./scripts/install-alwaysx11.sh --rollback
#
# Options:
#   --user       USERNAME   (required) desktop user account
#   --connector  PORT       HDMI connector name  (default: HDMI-A-1)
#   --mode       WxH@Hz     virtual display mode (default: 1920x1080@60)
#   --dm         UNIT       force DM unit name   (default: auto-detect)
#   --vnc                   enable x11vnc in headless mode
#   --rollback              undo a previous installation

set -euo pipefail

CONNECTOR="HDMI-A-1"
MODE="1920x1080@60"
TARGET_USER=""
ROLLBACK=false
FORCE_DM=""
ENABLE_VNC=false

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDID_HEX="$REPO_ROOT/assets/edid/alwaysx11-1920x1080.hex"
EDID_BIN="/lib/firmware/edid/alwaysx11-1920x1080.bin"
CMDLINE="/boot/firmware/cmdline.txt"
CONFIG="/boot/firmware/config.txt"
BACKUP_DIR="/var/lib/alwaysx11/backups"
INST_DIR="/etc/alwaysx11"
LIB_DIR="/usr/local/lib/alwaysx11"

log()  { echo "[alwaysx11] $*"; }
warn() { echo "[alwaysx11] WARN: $*" >&2; }
die()  { echo "[alwaysx11] ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="$2"; shift 2 ;;
        --connector) CONNECTOR="$2";   shift 2 ;;
        --mode)      MODE="$2";        shift 2 ;;
        --dm)        FORCE_DM="$2";    shift 2 ;;
        --vnc)       ENABLE_VNC=true;  shift   ;;
        --rollback)  ROLLBACK=true;    shift   ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "Must run as root (sudo ./scripts/install-alwaysx11.sh ...)"

# ── Rollback ──────────────────────────────────────────────────────────────────
if $ROLLBACK; then
    log "Rolling back AlwaysX11 installation..."
    for f in cmdline.txt config.txt; do
        bak="$BACKUP_DIR/$f.bak"
        dest="/boot/firmware/$f"
        if [[ -f "$bak" ]]; then cp "$bak" "$dest"; log "  Restored $dest"; fi
    done
    systemctl disable --now hdmi-watch.service 2>/dev/null || true
    rm -f /etc/systemd/system/hdmi-watch.service \
          /etc/systemd/system/xorg-dummy.service \
          /usr/local/bin/hdmi-switch.sh \
          "$EDID_BIN"
    rm -rf "$INST_DIR" "$LIB_DIR"
    systemctl daemon-reload
    log "Rollback complete. Please reboot: sudo reboot"
    exit 0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -n "$TARGET_USER" ]] || die "--user <username> is required"
id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' not found"
[[ -f "$EDID_HEX" ]]   || die "EDID hex not found: $EDID_HEX"
[[ -f "$CMDLINE" ]]    || die "Not a Pi 5 system? $CMDLINE missing"
[[ -f "$CONFIG" ]]     || die "Not a Pi 5 system? $CONFIG missing"

log "Installing AlwaysX11"
log "  User:      $TARGET_USER"
log "  Connector: $CONNECTOR"
log "  Mode:      $MODE"
[[ -n "$FORCE_DM" ]] && log "  Forced DM: $FORCE_DM"
$ENABLE_VNC && log "  VNC:       enabled"

# ── Backup ────────────────────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
for f in cmdline.txt config.txt; do
    src="/boot/firmware/$f"; bak="$BACKUP_DIR/$f.bak"
    if [[ ! -f "$bak" ]]; then
        cp "$src" "$bak"; log "Backed up $src → $bak"
    else
        log "Backup already exists: $bak (not overwriting)"
    fi
done

# ── Install packages ──────────────────────────────────────────────────────────
log "Installing xserver-xorg-video-dummy..."
apt-get install -y xserver-xorg-video-dummy

if $ENABLE_VNC; then
    log "Installing x11vnc..."
    apt-get install -y x11vnc
fi

# ── EDID binary ───────────────────────────────────────────────────────────────
log "Installing EDID firmware blob..."
mkdir -p "$(dirname "$EDID_BIN")"
xxd -r -p "$EDID_HEX" > "$EDID_BIN"
log "  EDID: $EDID_BIN"

# ── config.txt ────────────────────────────────────────────────────────────────
log "Patching /boot/firmware/config.txt..."
# Upgrade fkms → kms if present (Pi 5 requires kms)
if grep -q "dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
    sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$CONFIG"
    log "  Upgraded fkms → kms"
fi
grep -q "dtoverlay=vc4-kms-v3d" "$CONFIG"      || echo "dtoverlay=vc4-kms-v3d"      >> "$CONFIG"
grep -q "hdmi_force_hotplug:0=1" "$CONFIG"      || echo "hdmi_force_hotplug:0=1"     >> "$CONFIG"
grep -q "hdmi_force_hotplug:1=1" "$CONFIG"      || echo "hdmi_force_hotplug:1=1"     >> "$CONFIG"
grep -q "max_framebuffers=2"     "$CONFIG"      || echo "max_framebuffers=2"         >> "$CONFIG"
log "  config.txt OK"

# ── cmdline.txt ───────────────────────────────────────────────────────────────
log "Patching /boot/firmware/cmdline.txt..."
EDID_PARAM="drm.edid_firmware=${CONNECTOR}:edid/alwaysx11-1920x1080.bin"
VIDEO_PARAM="video=${CONNECTOR}:${MODE}e"
for param in "$EDID_PARAM" "$VIDEO_PARAM"; do
    if ! grep -qF "$param" "$CMDLINE"; then
        # cmdline.txt must be a single line — append in-place
        sed -i "s|$| $param|" "$CMDLINE"
        log "  Added: $param"
    else
        log "  Already present: $param"
    fi
done
# Normalize: remove trailing whitespace, ensure single newline
sed -i 's/[[:space:]]*$//' "$CMDLINE"; echo >> "$CMDLINE"

# ── DM-specific config ────────────────────────────────────────────────────────
# Detect which DM is installed and apply DM-specific tweaks only as needed.
DETECTED_DM=""
for unit in gdm gdm3; do
    if systemctl cat "${unit}.service" &>/dev/null || systemctl cat "$unit" &>/dev/null; then
        DETECTED_DM="$unit"; break
    fi
done

if [[ -n "$DETECTED_DM" ]]; then
    # GDM: disable Wayland so it falls back to X11
    for gdm_conf in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
        [[ -f "$gdm_conf" ]] || continue
        if grep -q "WaylandEnable=true" "$gdm_conf"; then
            sed -i 's/WaylandEnable=true/WaylandEnable=false/' "$gdm_conf"
            log "GDM: disabled Wayland in $gdm_conf"
        elif ! grep -q "WaylandEnable" "$gdm_conf"; then
            sed -i '/\[daemon\]/a WaylandEnable=false' "$gdm_conf"
            log "GDM: added WaylandEnable=false to $gdm_conf"
        else
            log "GDM: WaylandEnable already correct in $gdm_conf"
        fi
    done
else
    log "No GDM detected — skipping Wayland-disable step (not needed for SDDM/LightDM/etc)"
fi

# SDDM: ensure X11 session backend
for sddm_conf in /etc/sddm.conf /etc/sddm.conf.d/alwaysx11.conf; do
    if [[ "$sddm_conf" == "/etc/sddm.conf" ]]; then
        [[ -f "$sddm_conf" ]] || continue
    fi
    if systemctl cat sddm.service &>/dev/null || systemctl cat sddm &>/dev/null; then
        mkdir -p /etc/sddm.conf.d
        if [[ ! -f /etc/sddm.conf.d/alwaysx11.conf ]]; then
            cat > /etc/sddm.conf.d/alwaysx11.conf << 'SDDM'
# AlwaysX11 — force SDDM to use X11 display server
[General]
DisplayServer=x11
SDDM
            log "SDDM: created /etc/sddm.conf.d/alwaysx11.conf (force X11)"
        fi
        break
    fi
done

# ── Install configs and scripts ───────────────────────────────────────────────
log "Installing AlwaysX11 files..."
mkdir -p "$INST_DIR" "$LIB_DIR" /var/log/alwaysx11

# Xorg dummy config → /etc/alwaysx11/ (consistent location)
install -Dm644 "$REPO_ROOT/x11/xorg-dummy.conf"        "$INST_DIR/xorg-dummy.conf"

# Default runtime config (only if not already present — preserve user edits)
if [[ ! -f "$INST_DIR/alwaysx11.conf" ]]; then
    install -Dm644 "$REPO_ROOT/conf/alwaysx11.conf"    "$INST_DIR/alwaysx11.conf"
    # Inject forced DM and VNC settings if requested
    [[ -n "$FORCE_DM" ]] && sed -i "s|^#DM_SERVICE=.*|DM_SERVICE=$FORCE_DM|" "$INST_DIR/alwaysx11.conf" || true
    $ENABLE_VNC && sed -i "s|^VNC_ENABLE=false|VNC_ENABLE=true|" "$INST_DIR/alwaysx11.conf" || true
else
    log "  $INST_DIR/alwaysx11.conf already exists — not overwriting user config"
fi

# DM detection library
install -Dm755 "$REPO_ROOT/scripts/dm-detect.sh"       "$LIB_DIR/dm-detect.sh"

# Main watcher
install -Dm755 "$REPO_ROOT/scripts/hdmi-switch.sh"     /usr/local/bin/hdmi-switch.sh

# Systemd unit
install -Dm644 "$REPO_ROOT/systemd/hdmi-watch.service" /etc/systemd/system/hdmi-watch.service

# ── Enable service ────────────────────────────────────────────────────────────
log "Enabling hdmi-watch.service..."
systemctl daemon-reload
systemctl enable hdmi-watch.service
# Don't start yet — user needs to reboot for EDID/cmdline changes to take effect
# (starting now would race with the existing DM)
log "Service enabled (will start on next boot)"

log ""
log "═══════════════════════════════════════════════════════"
log " AlwaysX11 installation complete!"
log ""
log " Next steps:"
log "   1. Reboot:  sudo reboot"
log "   2. Verify:  sudo ./scripts/verify-alwaysx11.sh \\"
log "                   --user $TARGET_USER \\"
log "                   --connector $CONNECTOR"
log "   3. Status:  sudo journalctl -u hdmi-watch.service -f"
log "   4. Config:  sudo nano $INST_DIR/alwaysx11.conf"
log "   5. Undo:    sudo ./scripts/install-alwaysx11.sh --rollback"
log "═══════════════════════════════════════════════════════"
