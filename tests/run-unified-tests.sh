#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/logger"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" CONF_FILE="$tmp/config"
export RUN_DIR="$tmp/run" XORG_LOG_DIR="$tmp/log" DRM_ROOT="$tmp/drm"
printf 'MODE=combined\n' >"$CONF_FILE"
bash ghost-display.sh --mode virtual --dry-run >"$tmp/plan"
grep -q 'Mode: virtual' "$tmp/plan"
grep -q 'framebuffer=3840x1080' "$tmp/plan"
[[ ! -e "$RUN_DIR" && ! -e "$XORG_LOG_DIR" ]]
if bash ghost-display.sh --mode >"$tmp/error" 2>&1; then exit 1; fi
grep -q -- '--mode requires a value' "$tmp/error"
if POLL_INTERVAL=0 bash ghost-display.sh --dry-run >"$tmp/error" 2>&1; then exit 1; fi
grep -q 'POLL_INTERVAL must' "$tmp/error"

# Dry-run validation must reject invalid resolutions and degenerate scaling.
for bad in 'GHOST_RESOLUTION=garbage' 'GHOST_SCALE=0.00001'; do
  if env "$bad" scripts/ghost-display-x11.sh --dry-run >"$tmp/error" 2>&1; then
    echo "Invalid profile accepted: $bad" >&2; exit 1
  fi
done

# Preserve administrator-selected DM when modules are sourced.
DM_SERVICE=custom bash -c 'source lib/config-loader.sh; source lib/dm-manager.sh; [[ "$DM_SERVICE" == custom ]]'

# Lock paths are literal data, and dry-run does not interfere with a held lock.
mkdir "$RUN_DIR"
export LOCK_FILE="$RUN_DIR/lock" PID_FILE="$RUN_DIR/pid" STATE_FILE="$RUN_DIR/state"
bash -c 'source lib/config-loader.sh; source lib/logging.sh; source lib/state-manager.sh; init_locking; sleep 2' &
holder=$!
for _ in {1..50}; do [[ -f "$PID_FILE" ]] && break; sleep 0.02; done
bash ghost-display.sh --dry-run >"$tmp/plan"
if flock -n "$LOCK_FILE" true; then echo 'Dry-run released live lock' >&2; exit 1; fi
wait "$holder"

# Cleanup preserves failure status and the lock inode for the next daemon.
inode="$(stat -c %i "$LOCK_FILE")"
status=0
bash -c 'source lib/config-loader.sh; source lib/logging.sh; source lib/state-manager.sh;
  vnc_stop() { :; }; virtual_stop() { :; }; MODE=virtual;
  trap cleanup EXIT; exit 7' >"$tmp/cleanup" || status=$?
[[ "$status" == 7 && "$(stat -c %i "$LOCK_FILE")" == "$inode" ]]

# Missing credentials must never expose unauthenticated VNC on the network.
cat >"$tmp/bin/x11vnc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$VNC_TEST_ARGS"
MOCK
chmod +x "$tmp/bin/x11vnc"
export VNC_TEST_ARGS="$tmp/vnc-args" VNC_PASSWD_FILE="$tmp/no-password"
bash -c 'source lib/config-loader.sh; source lib/logging.sh; source lib/vnc-manager.sh; vnc_start' >"$tmp/vnc-log"
grep -qx -- '-localhost' "$VNC_TEST_ARGS"
grep -qx -- '-rfbport' "$VNC_TEST_ARGS"

# Both installers must reference an existing Xorg config with dual-display capacity.
[[ -f config/20-ghost-display.conf ]]
grep -q 'Virtual 8192 8192' config/20-ghost-display.conf
grep -q 'config/20-ghost-display.conf' install.sh
grep -q 'config/20-ghost-display.conf' scripts/install-ghost-display.sh

# Selector keeps Wayland only for a physical session and clears it for ghost X11.
mkdir -p "$DRM_ROOT/card0-HDMI-A-1"
printf 'connected\n' >"$DRM_ROOT/card0-HDMI-A-1/status"
export RUSTDESK_DRM_DIR="$DRM_ROOT" WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland
[[ "$(scripts/rustdesk-auto-display.sh --print)" == wayland:wayland-1 ]]
scripts/rustdesk-auto-display.sh bash -c '[[ "$WAYLAND_DISPLAY" == wayland-1 && "$XDG_SESSION_TYPE" == wayland ]]'
printf 'disconnected\n' >"$DRM_ROOT/card0-HDMI-A-1/status"
scripts/rustdesk-auto-display.sh bash -c '[[ "$DISPLAY" == :20 && "$XDG_SESSION_TYPE" == x11 && ! -v WAYLAND_DISPLAY ]]'
printf 'Unified entry point, validation, locking and selector checks passed.\n'
