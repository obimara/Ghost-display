# Ghost-display

A small X11 headless display for Debian Trixie / Raspberry Pi 5. It gives RustDesk a virtual multi-monitor workspace without HDMI, EDID, Wayland, or kernel-module setup.

## Design

- Xorg `dummy` driver.
- One headless X11 display, default `:20`.
- Logical monitors created with `xrandr --setmonitor`.
- Resolution, monitor count, layout, scale, and DPI are controlled by environment variables.
- Recommended default: two 1920x1080 monitors side by side.

This is a separate X11 session for RustDesk. It does not try to merge dummy outputs into a physical HDMI Xorg session, because that path is driver-dependent and less reliable.

## Files

- [`install.sh`](install.sh): one-command installer for dependencies, files, and systemd.
- [`config/20-ghost-display.conf`](config/20-ghost-display.conf): Xorg dummy config with common modes and `Virtual 8192 8192`.
- [`scripts/ghost-display-x11.sh`](scripts/ghost-display-x11.sh): starts Xorg, computes the layout, sets DPI, and creates XRandR monitors.
- [`scripts/compare-ghost-profiles.sh`](scripts/compare-ghost-profiles.sh): compares four practical profiles and recommends the balanced one.
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
GHOST_RESOLUTION=2560x1440 GHOST_DPI=120 sudo -E ./install.sh
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

```bash
DISPLAY=:20 rustdesk
```

For a RustDesk systemd service, add:

```ini
[Service]
Environment=DISPLAY=:20
```

RustDesk then sees one X11 framebuffer split into logical XRandR monitors.

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

Run syntax checks and the local test harness:

```bash
bash -n scripts/ghost-display-x11.sh scripts/compare-ghost-profiles.sh tests/run-ghost-display-tests.sh
tests/run-ghost-display-tests.sh
scripts/compare-ghost-profiles.sh
```

The test harness validates all four profiles, the oversized-framebuffer guard, and the runtime command sequence with mocked `Xorg`, `xrandr`, `xset`, and `xrdb`. It also verifies that stale `Ghost-*` monitors are removed without touching physical names such as `HDMI-A-1`.

## systemd

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
