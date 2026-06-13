#!/usr/bin/env bash
# INSTALL-ONE-LINER.sh — AlwaysX11 single-command installer
#
# Copy and paste the block below into a root shell on your Pi 5.
# Everything is self-contained — no git clone required.
#
# After it completes: sudo reboot

sudo bash -c '
set -euo pipefail
CONNECTOR="HDMI-A-1"
MODE="1920x1080@60"
EDID_HEX="00ffffffffffff004c2d010800000000\n2a1b0103803c2278ea5ec0a45b4b9826\n1352576100818081008180a9c081c0d1\nc00101010108e80030f2705a80b05870\n08205f2100001e023a801871382d40582c\n4500202f2100001e000000fd00324b1e\n5111000a202020202020000000fc0041\n6c776179735831310a20202020200119"

echo "[alwaysx11] Installing packages..."
apt-get install -y xserver-xorg-video-dummy

echo "[alwaysx11] Installing EDID blob..."
mkdir -p /lib/firmware/edid
printf "$EDID_HEX" | xxd -r -p > /lib/firmware/edid/alwaysx11-1920x1080.bin

echo "[alwaysx11] Backing up boot files..."
mkdir -p /var/lib/alwaysx11/backups
[[ -f /var/lib/alwaysx11/backups/cmdline.txt.bak ]] || cp /boot/firmware/cmdline.txt /var/lib/alwaysx11/backups/cmdline.txt.bak
[[ -f /var/lib/alwaysx11/backups/config.txt.bak  ]] || cp /boot/firmware/config.txt  /var/lib/alwaysx11/backups/config.txt.bak

echo "[alwaysx11] Patching config.txt..."
sed -i "s/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/" /boot/firmware/config.txt || true
grep -q "dtoverlay=vc4-kms-v3d"  /boot/firmware/config.txt || echo "dtoverlay=vc4-kms-v3d"  >> /boot/firmware/config.txt
grep -q "max_framebuffers=2"      /boot/firmware/config.txt || echo "max_framebuffers=2"      >> /boot/firmware/config.txt
grep -q "hdmi_force_hotplug:0=1" /boot/firmware/config.txt || echo "hdmi_force_hotplug:0=1" >> /boot/firmware/config.txt
grep -q "hdmi_force_hotplug:1=1" /boot/firmware/config.txt || echo "hdmi_force_hotplug:1=1" >> /boot/firmware/config.txt

echo "[alwaysx11] Patching cmdline.txt..."
grep -q "drm.edid_firmware=${CONNECTOR}" /boot/firmware/cmdline.txt || \
    sed -i "s/$/ drm.edid_firmware=${CONNECTOR}:edid\/alwaysx11-1920x1080.bin/" /boot/firmware/cmdline.txt
grep -q "video=${CONNECTOR}:" /boot/firmware/cmdline.txt || \
    sed -i "s/$/ video=${CONNECTOR}:${MODE}e/" /boot/firmware/cmdline.txt
sed -i "s/[[:space:]]*$//" /boot/firmware/cmdline.txt && echo >> /boot/firmware/cmdline.txt

echo "[alwaysx11] Disabling Wayland in GDM..."
if [[ -f /etc/gdm3/custom.conf ]]; then
    sed -i "s/WaylandEnable=true/WaylandEnable=false/" /etc/gdm3/custom.conf || true
    grep -q "WaylandEnable" /etc/gdm3/custom.conf || \
        sed -i "/\[daemon\]/a WaylandEnable=false" /etc/gdm3/custom.conf
fi

echo "[alwaysx11] Writing xorg-dummy.conf..."
cat > /etc/X11/xorg-dummy.conf << '"'"'EOF'"'"'
Section "Device"
    Identifier  "DummyDevice"
    Driver      "dummy"
    VideoRam    256000
EndSection
Section "Monitor"
    Identifier  "DummyMonitor"
    HorizSync   28.0-80.0
    VertRefresh 48.0-75.0
    Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection
Section "Screen"
    Identifier  "DummyScreen"
    Device      "DummyDevice"
    Monitor     "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1920x1080"
        Virtual 1920 1080
    EndSubSection
EndSection
EOF

echo "[alwaysx11] Writing hdmi-switch.sh (simulation-verified, bug-fixed)..."
cat > /usr/local/bin/hdmi-switch.sh << '"'"'EOF'"'"'
#!/usr/bin/env bash
# hdmi-switch.sh — AlwaysX11 HDMI state switcher
# Simulation-verified. Two bugs fixed vs original:
#   B1: stable_count now only resets after an actual switch (not on no-op)
#   B2: DRM_ROOT is injectable for testability (defaults to /sys/class/drm)
set -euo pipefail
POLL_INTERVAL="${POLL_INTERVAL:-1}"
STABLE_SECONDS="${STABLE_SECONDS:-5}"
LOG_TAG="hdmi-switch"
DRM_ROOT="${DRM_ROOT:-/sys/class/drm}"

log() { logger -t "$LOG_TAG" "$*"; echo "$(date "+%F %T") [$LOG_TAG] $*"; }

hdmi_connected() {
    local f
    for f in "${DRM_ROOT}"/card*-HDMI-A-*/status; do
        [[ -f "$f" ]] || continue
        [[ "$(cat "$f" 2>/dev/null)" == "connected" ]] && return 0
    done
    return 1
}

current_mode() {
    if systemctl is-active --quiet gdm; then echo "x11"; else echo "dummy"; fi
}

switch_to_x11() {
    log "Switching to X11/GNOME (gdm)"
    systemctl stop xorg-dummy.service 2>/dev/null || true
    systemctl start gdm
    log "Switch to X11 complete"
}

switch_to_dummy() {
    log "Switching to dummy Xorg (HDMI disconnected)"
    systemctl stop gdm 2>/dev/null || true
    systemctl start xorg-dummy.service
    log "Switch to dummy complete"
}

log "Started. POLL_INTERVAL=${POLL_INTERVAL}s  STABLE_SECONDS=${STABLE_SECONDS}s"
stable_count=0
last_target=""

while true; do
    hdmi_connected && target="x11" || target="dummy"

    if [[ "$target" != "$last_target" ]]; then
        stable_count=0; last_target="$target"
        log "State change detected → target=${target}, waiting for stability..."
    else
        (( stable_count++ )) || true
    fi

    if (( stable_count >= STABLE_SECONDS )); then
        mode="$(current_mode)"
        if [[ "$target" != "$mode" ]]; then
            log "Stable for ${STABLE_SECONDS}s — performing switch: ${mode} → ${target}"
            [[ "$target" == "x11" ]] && switch_to_x11 || switch_to_dummy
            stable_count=0  # FIX B1: only reset on actual switch
        fi
        # No reset here on no-op — counter keeps accumulating
    fi

    sleep "$POLL_INTERVAL"
done
EOF
chmod +x /usr/local/bin/hdmi-switch.sh

echo "[alwaysx11] Writing systemd units..."
cat > /etc/systemd/system/xorg-dummy.service << '"'"'EOF'"'"'
[Unit]
Description=Xorg dummy display (AlwaysX11 fallback)
After=systemd-udev-settle.service
[Service]
Type=simple
ExecStart=/usr/bin/Xorg :1 -config /etc/X11/xorg-dummy.conf -nolisten tcp
Restart=on-failure
RestartSec=3
EOF

cat > /etc/systemd/system/hdmi-watch.service << '"'"'EOF'"'"'
[Unit]
Description=HDMI hotplug watcher — AlwaysX11
After=network.target gdm.service
Wants=gdm.service
[Service]
Type=simple
ExecStart=/usr/local/bin/hdmi-switch.sh
Restart=always
RestartSec=5
Environment=POLL_INTERVAL=1
Environment=STABLE_SECONDS=5
[Install]
WantedBy=multi-user.target
EOF

echo "[alwaysx11] Enabling hdmi-watch.service..."
systemctl daemon-reload
systemctl enable --now hdmi-watch.service

echo ""
echo "✓ AlwaysX11 installed successfully."
echo "  Next step: sudo reboot"
'
