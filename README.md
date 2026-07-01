# Ghost Display v2

**Unified Virtual X11 Display and HDMI Hotplug Manager for Raspberry Pi 5**

Ghost Display v2 combines the best of **AlwaysX11** and **Ghost-display-x11** into a single, powerful solution that:
- Creates **persistent virtual X11 displays** for RustDesk and other remote desktop tools
- **Monitors HDMI hotplug** events to automatically switch between physical and virtual displays
- Works **seamlessly with any display manager** (GDM, SDDM, LightDM, etc.) or in headless mode
- Provides a **"ghost" display** that's always available, even when no physical monitor is connected

---

## 🎯 Use Cases

### Primary Use Case: RustDesk with iPad
```
Pi 5 + Ghost Display + RustDesk + iPad
   ↓
   Connect iPad as main monitor
   ↓
   Use iPad keyboard/trackpad to control Pi5
   ↓
   Optionally connect physical HDMI monitor for dual-screen
```

### Additional Use Cases
- **Headless server** with occasional monitor connection
- **Remote desktop** access without physical display
- **Kiosk systems** that need to work with or without monitors
- **Development environments** with flexible display configurations

---

## 📦 What's New in v2

Ghost Display v2 is a **complete merge** of:
1. **AlwaysX11** - HDMI hotplug detection and display manager switching
2. **Ghost-display-x11** - Virtual X11 display creation for RustDesk

### Key Improvements
- ✅ **Single unified script** (`ghost-display.sh`) with multiple modes
- ✅ **Modular architecture** - easy to maintain and extend
- ✅ **Backward compatible** - supports old AlwaysX11 configurations
- ✅ **RustDesk optimized** - designed specifically for this use case
- ✅ **Universal platform support** (future goal)

---

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/obimara/Ghost-display.git
cd Ghost-display

# Run the installer (as root)
sudo ./scripts/install-ghost-display.sh --user YOUR_USERNAME

# Reboot for changes to take effect
sudo reboot
```

### After Reboot

```bash
# Check that the service is running
sudo systemctl status ghost-display.service

# View logs
sudo journalctl -u ghost-display.service -f

# Verify installation
sudo ./scripts/verify-ghost-display.sh
```

### Using with RustDesk

```bash
# Start RustDesk with the virtual display
DISPLAY=:20 rustdesk

# Or create a desktop shortcut with:
# Exec=env DISPLAY=:20 rustdesk
```

---

## 🎛️ Modes of Operation

Ghost Display supports three modes, configured via the `MODE` setting:

| Mode | Description | Use Case |
|------|-------------|----------|
| `virtual` | Pure virtual display only | RustDesk without physical monitor |
| `hotplug` | HDMI hotplug monitoring only | Like AlwaysX11, switches between DM and dummy Xorg |
| `combined` | Both virtual + HDMI monitoring | **Recommended** - virtual always on, plus HDMI switching |

### Changing Mode

Edit `/etc/ghost-display/ghost-display.conf`:
```bash
MODE=combined  # Change to virtual, hotplug, or combined
```

Then restart the service:
```bash
sudo systemctl restart ghost-display.service
```

---

## 📝 Configuration

### Main Configuration File

Edit `/etc/ghost-display/ghost-display.conf`:

```bash
# Mode of operation
MODE=combined

# Virtual Display Settings
VIRTUAL_DISPLAY_NUM=20      # Display number (:20)
VIRTUAL_MONITORS=2           # Number of virtual monitors
VIRTUAL_RESOLUTION=1920x1080 # Default resolution
VIRTUAL_SCALE=1.0            # Scaling factor
VIRTUAL_DPI=96              # DPI setting
VIRTUAL_LAYOUT=horizontal   # horizontal or vertical
VIRTUAL_NAME_PREFIX=Ghost   # Monitor name prefix

# Custom monitor specifications (overrides above)
# Format: "WIDTHxHEIGHT@SCALE,WIDTHxHEIGHT@SCALE,..."
VIRTUAL_MONITOR_SPECS=1920x1080@1,2560x1440@1.25

# HDMI Hotplug Settings
HDMI_POLL_INTERVAL=1        # Seconds between HDMI polls
HDMI_STABLE_SECONDS=5       # Anti-flap threshold

# Display Manager
DM_SERVICE=                 # Leave blank for auto-detection

# VNC (optional)
VNC_ENABLE=false
VNC_PORT=5900
VNC_PASSWD_FILE=/etc/ghost-display/vncpasswd

# Logging
LOG_LEVEL=info             # debug, info, warn, error
LOG_FILE=/var/log/ghost-display.log
```

### Environment Variables

All configuration options can also be set via environment variables:
- `GHOST_MODE` or `MODE`
- `GHOST_DISPLAY_NUM` or `VIRTUAL_DISPLAY_NUM`
- `GHOST_MONITORS` or `VIRTUAL_MONITORS`
- etc.

---

## 🔧 Command Line Options

```bash
# Start Ghost Display
sudo ghost-display.sh [OPTIONS]

# Options:
--mode MODE          virtual, hotplug, or combined (default: combined)
--dry-run            Show configuration without starting
--foreground         Run in foreground (for debugging)
--rollback           Remove Ghost Display installation
-h, --help           Show help
```

### Examples

```bash
# Show current configuration without starting
sudo ghost-display.sh --dry-run

# Start in pure virtual mode
sudo ghost-display.sh --mode virtual

# Run in foreground for debugging
sudo ghost-display.sh --foreground

# Uninstall Ghost Display
sudo ghost-display.sh --rollback
```

---

## 📁 File Structure

```
ghost-display/
├── ghost-display.sh              # Main entry point
├── lib/                          # Library modules
│   ├── config-loader.sh          # Configuration management
│   ├── logging.sh                # Logging system
│   ├── hdmi-monitor.sh           # HDMI hotplug detection
│   ├── x11-virtual.sh            # Virtual X11 display management
│   ├── dm-manager.sh             # Display manager control
│   ├── vnc-manager.sh            # VNC management
│   └── state-manager.sh          # State tracking and locking
├── config/
│   └── ghost-display.conf        # Default configuration
├── systemd/
│   └── ghost-display.service     # Systemd service unit
├── x11/
│   └── ghost-display.conf        # Xorg configuration for virtual display
├── scripts/
│   ├── install-ghost-display.sh  # Installer
│   └── verify-ghost-display.sh   # Verification script
├── assets/
│   └── edid/
│       └── alwaysx11-1920x1080.hex  # EDID firmware
└── README.md
```

---

## 🔄 Migration from AlwaysX11

If you were using **AlwaysX11** previously:

1. **Backup your configuration:**
   ```bash
   sudo cp /etc/alwaysx11/alwaysx11.conf /etc/alwaysx11/alwaysx11.conf.bak
   ```

2. **Install Ghost Display v2:**
   ```bash
   sudo ./scripts/install-ghost-display.sh --user YOUR_USERNAME
   ```

3. **The installer will automatically:**
   - Migrate your old configuration
   - Convert variable names (e.g., `DUMMY_DISPLAY` → `VIRTUAL_DISPLAY`)
   - Preserve your settings

4. **Restart the service:**
   ```bash
   sudo systemctl restart ghost-display.service
   ```

---

## 🔒 Security

Ghost Display is designed to work with **Tailscale VPN**:
- RustDesk runs over Tailscale
- Only allowed units on your Tailscale network can connect
- No exposure to the public internet

### VNC Security

If you enable VNC (`VNC_ENABLE=true`):
1. **Always set a password:**
   ```bash
   sudo x11vnc -storepasswd /etc/ghost-display/vncpasswd
   ```
2. **Use Tailscale** to restrict access
3. **Consider firewall rules** to block external VNC connections

---

## 🐛 Troubleshooting

### Common Issues

**Issue: Ghost Display won't start**
```bash
# Check service status
sudo systemctl status ghost-display.service

# View logs
sudo journalctl -u ghost-display.service -f
```

**Issue: RustDesk can't connect**
```bash
# Verify virtual display is running
ls /tmp/.X20-lock  # Should exist

# Check Xorg process
pgrep -f "Xorg :20"

# Try connecting manually
DISPLAY=:20 xset q
```

**Issue: HDMI hotplug not working**
```bash
# Check HDMI status manually
cat /sys/class/drm/card*-HDMI-A-*/status

# Check DRM permissions
ls -la /sys/class/drm/
```

**Issue: Display manager not starting**
```bash
# Check which DM is detected
sudo systemctl status display-manager.service

# Try starting DM manually
sudo systemctl start gdm.service  # or sddm, lightdm, etc.
```

### Debug Mode

Run with debug logging:
```bash
sudo ghost-display.sh --foreground --mode combined
```

Or edit the config:
```bash
LOG_LEVEL=debug
```

---

## 🧪 Testing

Ghost Display includes a comprehensive test suite:

```bash
# Run all tests
bash tests/stress.sh

# Run specific category
bash tests/stress.sh -c INTEG
bash tests/stress.sh -c EDGE
bash tests/stress.sh -c RACE

# Verbose output
bash tests/stress.sh -v
```

---

## 📊 Bug Fixes from AlwaysX11 v3

Ghost Display v2 includes all fixes from AlwaysX11 v3:

| ID | Description | Status |
|----|-------------|--------|
| B1 | Hardcoded `After=gdm.service` | ✅ Fixed |
| B2 | Non-atomic lock | ✅ Fixed (using flock) |
| B3 | `xdpyinfo` dependency | ✅ Fixed (polls X lock file) |
| B4 | Wasteful `tr` subprocess | ✅ Fixed (pure bash read) |
| B5 | Stale STATE_FILE at boot | ✅ Fixed |
| B6 | Uninitialized DM vars | ✅ Fixed |
| B7 | Xorg logfile dir not created | ✅ Fixed |
| B8 | State set even when DM failed | ✅ Fixed |

---

## 🎓 How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Ghost Display v2                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────┐ │
│  │ HDMI Monitor    │    │ Virtual X11      │    │ DM      │ │
│  │ (hdmi-monitor)  │    │ (x11-virtual)    │    │ Manager │ │
│  └────────┬────────┘    └────────┬────────┘    └────┬────┘ │
│           │                      │                   │       │
│           └──────────────────────┼───────────────────┘       │
│                                  ▼                               │
│                         ┌─────────────┐                         │
│                         │   State     │                         │
│                         │  Manager    │                         │
│                         └─────────────┘                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Mode: Combined (Recommended)

```
1. Virtual display always runs on :20 (or configured display)
2. HDMI hotplug detection runs in background
3. If HDMI connected:
   - Display manager starts (if installed)
   - Physical monitor becomes available
   - State: combined_display
4. If HDMI disconnected:
   - Display manager stops
   - Only virtual display remains
   - State: combined_headless
5. RustDesk always connects to virtual display (:20)
```

### Anti-Flap Debouncing

The daemon only acts after HDMI state has been **stable for N seconds** (default: 5). This prevents flickering from:
- Cable wiggle
- TV power cycling
- Transient disconnections

---

## 📄 License

MIT License - see `LICENSE` file for details.

---

## 🙏 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run the test suite: `bash tests/stress.sh`
5. Submit a pull request

---

## 📞 Support

- **GitHub Issues:** https://github.com/obimara/Ghost-display/issues
- **Discussions:** https://github.com/obimara/Ghost-display/discussions

---

*Ghost Display v2 - Making headless computing seamless since 2024*
