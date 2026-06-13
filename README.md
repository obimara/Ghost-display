# AlwaysX11

**Persistent HDMI output for Raspberry Pi 5 — works with any display manager or none.**

AlwaysX11 keeps an X11 display session alive at all times on a Pi 5:
- **HDMI connected** → starts your display manager (GDM, SDDM, LightDM, …) for a real login screen
- **HDMI unplugged** → switches to a dummy Xorg session (invisible, headless) so GPU, Wayland compositors, and remote VNC tools keep working

No more "black screen on reconnect". No more GPU dying because nothing was attached.

---

## Contents

```
alwaysx11/
├── scripts/
│   ├── hdmi-switch.sh          # Main daemon — the hotplug watcher
│   ├── dm-detect.sh            # DM auto-detection library
│   ├── install-alwaysx11.sh    # Installer (DM-agnostic)
│   └── verify-alwaysx11.sh     # Post-install sanity check
├── systemd/
│   └── hdmi-watch.service      # Systemd unit
├── x11/
│   └── xorg-dummy.conf         # Xorg config for headless dummy driver
├── conf/
│   └── alwaysx11.conf          # Runtime tunables
├── assets/
│   └── edid/                   # EDID firmware for forced-hotplug
└── tests/
    ├── stress.sh                # 149-test comprehensive suite
    └── sim/                     # Simulation harness (fake systemctl/Xorg)
```

---

## Quick Install

```bash
git clone https://github.com/YOUR_HANDLE/alwaysx11.git
cd alwaysx11
sudo bash scripts/install-alwaysx11.sh --user "$USER"
sudo reboot
```

After reboot:
```bash
bash scripts/verify-alwaysx11.sh --user "$USER"
```

---

## Requirements

| Item | Notes |
|------|-------|
| Raspberry Pi 5 | Tested on Raspberry Pi OS Bookworm (Debian 12) |
| Kernel ≥ 6.6 | Ships with Pi OS Bookworm |
| `xserver-xorg-video-dummy` | Installed automatically |
| Display manager | **Optional** — any of GDM, SDDM, LightDM, LXDM, XDM, SLiM, nodm; or none |
| `x11vnc` | Optional — for remote access in headless mode |

---

## How it works

```
                   ┌─────────────────────────────────┐
                   │        hdmi-switch.sh            │
                   │                                  │
  DRM sysfs ──────►│  hdmi_connected()                │
  /sys/class/drm   │  (pure bash read, zero forks)    │
                   │           │                      │
                   │    stable │ for N ticks          │
                   │           ▼                      │
              ┌────┤  switch_to_display()              │
              │    │    • stop dummy Xorg             │
              │    │    • dm_start() via systemctl    │
              │    │                                  │
              │    │  switch_to_headless()             │
              │    │    • dm_stop() via systemctl     │
              │    │    • start dummy Xorg (:1)       │
              │    │    • optional x11vnc             │
              │    │                                  │
              │    │  watchdog: resurrect dead Xorg   │
              └────┴─────────────────────────────────┘
```

### Anti-flap debouncing

The daemon only acts after the HDMI state has been **stable for `STABLE_SECONDS` consecutive poll ticks** (default: 5 × 1 s = 5 s). Transient disconnects (cable wiggle, TV power cycle) are ignored.

---

## Supported display managers

| DM | Package | Detection |
|----|---------|-----------|
| GDM | `gdm3` | auto |
| SDDM | `sddm` | auto |
| LightDM | `lightdm` | auto |
| LXDM | `lxdm` | auto |
| XDM | `xdm` | auto |
| SLiM | `slim` | auto |
| nodm | `nodm` | auto |
| *none* | — | headless-only mode |

Override auto-detection:
```bash
# In /etc/alwaysx11/alwaysx11.conf:
DM_SERVICE=sddm
```

---

## Configuration

Edit `/etc/alwaysx11/alwaysx11.conf` or pass env vars via a systemd drop-in:

```bash
sudo systemctl edit hdmi-watch.service
# Then add:
[Service]
Environment=POLL_INTERVAL=2
Environment=STABLE_SECONDS=10
```

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `1` | Seconds between HDMI polls |
| `STABLE_SECONDS` | `5` | Stable ticks before switching |
| `DRM_ROOT` | `/sys/class/drm` | DRM sysfs path |
| `DM_SERVICE` | auto | Force a specific DM unit name |
| `DUMMY_DISPLAY` | `:1` | X display for headless session |
| `DUMMY_XORG_CONF` | `/etc/alwaysx11/xorg-dummy.conf` | Xorg dummy config |
| `VNC_ENABLE` | `false` | Start x11vnc in headless mode |
| `VNC_PORT` | `5900` | x11vnc port |
| `VNC_PASSWD_FILE` | `/etc/alwaysx11/vncpasswd` | x11vnc rfbauth file |
| `LOG_LEVEL` | `info` | `debug`\|`info`\|`warn`\|`error` |
| `LOG_FILE` | — | Also log to this file |
| `WAIT_TIMEOUT_S` | `10` | Seconds to wait for DM start/stop |

---

## VNC (optional)

```bash
# Generate a VNC password
x11vnc -storepasswd /etc/alwaysx11/vncpasswd

# Enable in config
echo 'VNC_ENABLE=true' >> /etc/alwaysx11/alwaysx11.conf
sudo systemctl restart hdmi-watch.service
```

Connect with any VNC client to `<pi-ip>:5900`.

---

## Rollback

```bash
sudo bash scripts/install-alwaysx11.sh --rollback
sudo reboot
```

---

## Running the test suite

```bash
# All 149 tests
bash tests/stress.sh

# Single category
bash tests/stress.sh -c INTEG   # live integration
bash tests/stress.sh -c EDGE    # boundary conditions
bash tests/stress.sh -c RACE    # concurrent access
bash tests/stress.sh -c FAULT   # fault injection
bash tests/stress.sh -c STRESS  # endurance
bash tests/stress.sh -c LEAK    # fd/zombie/signal
bash tests/stress.sh -c STATIC  # script analysis
bash tests/stress.sh -c UNIT    # pure logic
```

No root required. No hardware required. Everything runs against a fake sysfs/systemctl/Xorg in `tests/sim/`.

---

## Bugs fixed in v3

| ID | Description |
|----|-------------|
| B1 | Service hardcoded `After=gdm.service` — broke on SDDM/LightDM |
| B2 | Non-atomic lock (`test -f` → `echo $$`) — race condition |
| B3 | `xdpyinfo` dep for X readiness — not always installed |
| B4 | `tr -d '[:space:]'` subprocess per poll tick — wasteful |
| B5 | `STATE_FILE` relied on stale `/run` value at boot |
| B6 | DM label vars uninitialized before loop — crashes with `set -u` |
| B7 | Xorg logfile dir not created — silent failure |
| B8 | `switch_to_display` set `state=display` even when DM failed |

---

## License

MIT. See `LICENSE`.
