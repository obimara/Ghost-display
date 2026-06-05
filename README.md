# Ghost-display

A small X11 headless display for Debian Trixie / Raspberry Pi 5. It gives RustDesk a virtual multi-monitor workspace without HDMI, EDID, Wayland, or kernel-module setup.

## Design

- Xorg `dummy` driver.
- One headless X11 display, default `:20`.
- Logical monitors created with `xrandr --setmonitor`.
- Resolution, monitor count, layout, scale, and DPI are controlled by environment variables.
- Recommended default: two 1920x1080 monitors side by side.

This is a separate X11 session for RustDesk. It does not try to merge dummy outputs into a physical HDMI Xorg session, because that path is driver-dependent and less reliable.

Wayland note: the headless fallback is still X11 because compositor-native Wayland virtual outputs are not universal across GNOME, KDE, wlroots, and Weston. The RustDesk wrapper can preserve an already-running Wayland session, then fall back to a physical X display or the ghost X11 display when Wayland is not available.

## Files

- [`install.sh`](install.sh): one-command installer for dependencies, files, and systemd.
- [`config/20-ghost-display.conf`](config/20-ghost-display.conf): Xorg dummy config with common modes and `Virtual 8192 8192`.
- [`scripts/ghost-display-x11.sh`](scripts/ghost-display-x11.sh): starts Xorg, computes the layout, sets DPI, and creates XRandR monitors.
- [`scripts/compare-ghost-profiles.sh`](scripts/compare-ghost-profiles.sh): compares four practical profiles and recommends the balanced one.
- [`scripts/debug-ghost-display.sh`](scripts/debug-ghost-display.sh): prints dependency, service, DRM, and XRandR diagnostics.
- [`scripts/rustdesk-auto-display.sh`](scripts/rustdesk-auto-display.sh): starts RustDesk on the current Wayland session, physical X display, or ghost X display.
- [`systemd/ghost-display-x11.service`](systemd/ghost-display-x11.service): optional systemd unit.
- [`tests/run-ghost-display-tests.sh`](tests/run-ghost-display-tests.sh): dry-run and mocked-runtime test harness.

## Dependencies

```bash
sudo apt update
sudo apt install --yes xserver-xorg-core xserver-xorg-video-dummy x11-xserver-utils x11-utils
```

Optional for local linting:

```bash
sudo apt install --yes shellcheck
```

## Fast install

Copy and paste this from the repository root for a complete install with dependencies, config, runtime script, profile comparison tool, and systemd service:

```bash
sudo ./install.sh && DISPLAY=:20 xrandr --listmonitors
```

Custom profile example:

```bash
GHOST_RESOLUTION=2560x1440 GHOST_DPI=120 GHOST_XORG_LOG=/var/log/ghost-display-20.log sudo -E ./install.sh
```

If you want to install files without starting the service:

```bash
sudo ./install.sh --no-start
```

Verify later:

```bash
DISPLAY=:20 xrandr --listmonitors
```

Expected default shape:

```text
Monitors: 2
 0: Ghost-1 1920/508x1080/286+0+0
 1: Ghost-2 1920/508x1080/286+1920+0
```

## Run RustDesk

Force RustDesk to the ghost display:

```bash
DISPLAY=:20 rustdesk
```

Automatically choose the display in one line:

```bash
rustdesk-auto-display
```

`rustdesk-auto-display` keeps the current Wayland session when a physical DRM connector is connected and `WAYLAND_DISPLAY` is present. If Wayland is not available, it chooses `:0` when that X display responds to `xset`; otherwise it chooses the ghost display `:20`. Override with `RUSTDESK_PHYSICAL_DISPLAY`, `RUSTDESK_GHOST_DISPLAY`, or `RUSTDESK_PREFER_WAYLAND=0` if needed.

For a RustDesk systemd service, use the wrapper as the command:

```ini
[Service]
ExecStart=/usr/local/bin/rustdesk-auto-display rustdesk
```

RustDesk then starts on the active Wayland session when available, the physical X display when available, or the ghost X11 framebuffer when no usable physical session is found.

## Screen options

| Variable | Default | Meaning |
| --- | --- | --- |
| `GHOST_DISPLAY_NUM` | `20` | Display number when `GHOST_DISPLAY` is unset. |
| `GHOST_DISPLAY` | `:20` | Full X11 display name. |
| `GHOST_MONITORS` | `2` | Number of identical monitors. Ignored when `GHOST_MONITOR_SPECS` is set. |
| `GHOST_RESOLUTION` | `1920x1080` | Base resolution per monitor. |
| `GHOST_SCALE` | `1.0` | Pixel scale. `1.25` turns 1920x1080 into 2400x1350. |
| `GHOST_DPI` | `96` | Advertised monitor DPI and `Xft.dpi`. |
| `GHOST_LAYOUT` | `horizontal` | `horizontal` or `vertical`. |
| `GHOST_NAME_PREFIX` | `Ghost` | Monitor name prefix. |
| `GHOST_MONITOR_SPECS` | empty | Per-monitor specs: `WIDTHxHEIGHT[@SCALE],...`. |
| `GHOST_XORG_LOG` | `/var/log/ghost-display-N.log` as root, `/tmp/ghost-display-N.log` otherwise | Xorg log path. `N` follows the active display, including custom `GHOST_DISPLAY` values. |
| `GHOST_DRY_RUN` | `0` | Set to `1` to print the plan without starting Xorg. |
| `GHOST_MAX_WIDTH` / `GHOST_MAX_HEIGHT` | `8192` | Safety limit matching the sample Xorg `Virtual` size. |

## Profiles

Default dual 1080p:

```bash
GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 /usr/local/bin/ghost-display-x11
```

Scaled dual 1080p:

```bash
GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 GHOST_SCALE=1.25 /usr/local/bin/ghost-display-x11
```

Mixed workspace:

```bash
GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1 GHOST_DPI=110 /usr/local/bin/ghost-display-x11
```

Vertical triple 720p:

```bash
GHOST_MONITORS=3 GHOST_RESOLUTION=1280x720 GHOST_LAYOUT=vertical /usr/local/bin/ghost-display-x11
```

Dry-run any profile first:

```bash
GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1.25 /usr/local/bin/ghost-display-x11 --dry-run
```

## Compare and choose

Run:

```bash
scripts/compare-ghost-profiles.sh
```

The four profiles are intentionally different:

- `balanced-dual`: two 1080p monitors, 3840x1080, ~15.8 MiB framebuffer. Best default.
- `scaled-dual`: two scaled monitors, 4800x1350, ~24.7 MiB. More workspace, more RustDesk encode cost.
- `mixed-workspace`: 1080p + 1440p, 4480x1440, ~24.6 MiB. Useful when one monitor needs detail.
- `vertical-triple`: three 720p monitors, 1280x2160, ~10.5 MiB. Lowest pixel cost, but not a normal dual-monitor shape.

Finished recommendation: use `balanced-dual` unless you specifically need more workspace. It keeps RustDesk dual-monitor behavior simple and avoids the ~+9 MiB framebuffer increase of the scaled and mixed profiles.

## Debug and test

Run the intensive local check before pushing to GitHub:

```bash
tests/run-intensive-tests.sh
```

For individual checks:

```bash
bash -n install.sh scripts/*.sh tests/*.sh
tests/run-ghost-display-tests.sh
scripts/compare-ghost-profiles.sh
```

The test harness validates all four profiles, invalid inputs, width and height framebuffer guards, the runtime command sequence with mocked `Xorg`, `xrandr`, `xset`, and `xrdb`, and Wayland/X11/ghost RustDesk display selection. It also verifies that stale `Ghost-*` monitors are removed without touching physical names such as `HDMI-A-1`.

For a field debug report after install, run:

```bash
ghost-display-debug
```

## systemd

The bundled service keeps the ghost Xorg process tied to systemd with `GHOST_STAY_FOREGROUND=1` and restarts it on failure.

```bash
sudo cp config/20-ghost-display.conf /etc/X11/ghost-display.conf
sudo install -m 0755 scripts/ghost-display-x11.sh /usr/local/bin/ghost-display-x11
sudo cp systemd/ghost-display-x11.service /etc/systemd/system/ghost-display-x11.service
sudo systemctl daemon-reload
sudo systemctl enable --now ghost-display-x11.service
```

Override the profile:

```bash
sudo systemctl edit ghost-display-x11.service
```

Example drop-in:

```ini
[Service]
Environment=GHOST_MONITORS=2
Environment=GHOST_RESOLUTION=2560x1440
Environment=GHOST_DPI=120
Environment=GHOST_SCALE=1.0
Environment=GHOST_LAYOUT=horizontal
```

Verify:

```bash
systemctl status ghost-display-x11.service
DISPLAY=:20 xrandr --listmonitors
```
