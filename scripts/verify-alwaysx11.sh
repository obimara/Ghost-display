#!/usr/bin/env bash
# verify-alwaysx11.sh — Post-reboot verification for AlwaysX11
#
# Usage:
#   ./scripts/verify-alwaysx11.sh --user "$USER" --connector HDMI-A-1

set -euo pipefail

CONNECTOR="HDMI-A-1"
TARGET_USER=""
PASS=0
FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="$2"; shift 2 ;;
        --connector) CONNECTOR="$2";   shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

ok()   { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
info() { echo "  [INFO] $*"; }

echo ""
echo "═══════════════════════════════════════════"
echo "  AlwaysX11 — Post-Reboot Verification"
echo "═══════════════════════════════════════════"
echo ""

# ── EDID firmware ─────────────────────────────────────────────────────────────
echo "── EDID firmware ──"
EDID_BIN="/lib/firmware/edid/alwaysx11-1920x1080.bin"
if [[ -f "$EDID_BIN" ]]; then
    ok "EDID blob present: $EDID_BIN"
else
    fail "EDID blob missing: $EDID_BIN"
fi

# ── cmdline.txt ───────────────────────────────────────────────────────────────
echo ""
echo "── /boot/firmware/cmdline.txt ──"
CMDLINE="$(cat /boot/firmware/cmdline.txt 2>/dev/null || true)"
if echo "$CMDLINE" | grep -q "drm.edid_firmware=${CONNECTOR}"; then
    ok "drm.edid_firmware param present"
else
    fail "drm.edid_firmware param MISSING"
fi
if echo "$CMDLINE" | grep -q "video=${CONNECTOR}:"; then
    ok "video= param present"
else
    fail "video= param MISSING"
fi

# ── config.txt ────────────────────────────────────────────────────────────────
echo ""
echo "── /boot/firmware/config.txt ──"
CONFIG="$(cat /boot/firmware/config.txt 2>/dev/null || true)"
for param in "dtoverlay=vc4-kms-v3d" "max_framebuffers=2" "hdmi_force_hotplug:0=1" "hdmi_force_hotplug:1=1"; do
    if echo "$CONFIG" | grep -q "$param"; then
        ok "$param present"
    else
        fail "$param MISSING"
    fi
done

# ── GDM Wayland disabled ──────────────────────────────────────────────────────
echo ""
echo "── GDM configuration ──"
GDM_CONF="/etc/gdm3/custom.conf"
if grep -q "WaylandEnable=false" "$GDM_CONF" 2>/dev/null; then
    ok "WaylandEnable=false set in gdm3"
else
    fail "WaylandEnable=false NOT set in $GDM_CONF"
fi

# ── DRM connector status ──────────────────────────────────────────────────────
echo ""
echo "── DRM connector status ──"
found=false
for f in /sys/class/drm/card*-HDMI-A-*/status; do
    [[ -f "$f" ]] || continue
    found=true
    status="$(cat "$f")"
    info "$(basename "$(dirname "$f")"): $status"
done
$found || fail "No DRM HDMI connectors found in /sys/class/drm/"

# ── Xorg dummy package ────────────────────────────────────────────────────────
echo ""
echo "── Packages ──"
if dpkg -l xserver-xorg-video-dummy &>/dev/null; then
    ok "xserver-xorg-video-dummy installed"
else
    fail "xserver-xorg-video-dummy NOT installed"
fi

# ── Xorg dummy config ─────────────────────────────────────────────────────────
echo ""
echo "── Xorg dummy config ──"
if [[ -f /etc/X11/xorg-dummy.conf ]]; then
    ok "/etc/X11/xorg-dummy.conf present"
else
    fail "/etc/X11/xorg-dummy.conf MISSING"
fi

# ── systemd services ──────────────────────────────────────────────────────────
echo ""
echo "── systemd services ──"
for svc in hdmi-watch.service xorg-dummy.service gdm.service; do
    state="$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")"
    info "$svc: $state"
done

if systemctl is-enabled --quiet hdmi-watch.service 2>/dev/null; then
    ok "hdmi-watch.service is enabled"
else
    fail "hdmi-watch.service is NOT enabled"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════"
echo ""
if (( FAIL > 0 )); then
    echo "  Some checks failed. Review output above."
    exit 1
else
    echo "  All checks passed. AlwaysX11 is healthy."
    exit 0
fi
