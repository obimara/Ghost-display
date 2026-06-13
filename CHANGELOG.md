# Changelog

## v3.0.0 — 2026-03-04

### Changed
- Fully desktop-manager agnostic (GDM, SDDM, LightDM, LXDM, XDM, SLiM, nodm, headless)
- DM detection via `dm-detect.sh` library with priority: active > enabled > installed
- `DM_SERVICE` env override for custom/unsupported DMs

### Fixed
- **B1** `hdmi-watch.service`: removed `After/Wants=gdm.service` hardcode
- **B2** Lock: replaced non-atomic check-then-write with `flock(1)`
- **B3** X readiness: removed `xdpyinfo` dependency; poll lock file + socket instead
- **B4** `hdmi_connected`: replaced `tr` subprocess with bash `read` builtin (zero forks/poll)
- **B5** Startup: derive initial state from live HDMI state, not stale `/run/state`
- **B6** `dm-detect.sh`: declare all label variables before loop (`set -u` safe)
- **B7** `dummy_start`: `mkdir -p /var/log/alwaysx11` before Xorg `-logfile`
- **B8** `switch_to_display`: set `state=display_error` on DM timeout, not silent success

### Added
- `dm-detect.sh` standalone library (can be sourced by other scripts)
- `XORG_BIN` override for test harness injection
- `DM_SIM` env for simulation harness
- 149-test suite across 8 categories (UNIT/INTEG/EDGE/RACE/FAULT/STRESS/LEAK/STATIC)

## v2.0.0 — 2026-03-03

- Added VNC support via `x11vnc`
- Added display manager detection (GDM-only)
- Improved anti-flap debouncing

## v1.0.0 — 2026-03-02

- Initial release
- Basic HDMI hotplug → headless/display switching
