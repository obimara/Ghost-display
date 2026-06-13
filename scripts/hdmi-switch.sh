#!/usr/bin/env bash
# hdmi-switch.sh — AlwaysX11 v3 HDMI hotplug watcher
# Desktop-manager agnostic: GDM, SDDM, LightDM, LXDM, XDM, nodm, SLiM, or none.
set -euo pipefail

RUN_DIR="${RUN_DIR:-/run/alwaysx11}"
mkdir -p "$RUN_DIR"
LOCK_FD=9; LOCK_FILE="$RUN_DIR/hdmi-switch.lock"
PID_FILE="$RUN_DIR/hdmi-switch.pid"; STATE_FILE="$RUN_DIR/state"
DUMMY_PID_FILE="$RUN_DIR/xorg-dummy.pid"; VNC_PID_FILE="$RUN_DIR/x11vnc.pid"

# FIX B2: atomic flock — no TOCTOU race
eval "exec $LOCK_FD>\"$LOCK_FILE\""
if ! flock -n $LOCK_FD 2>/dev/null; then
    echo "AlwaysX11: already running (PID $(cat "$PID_FILE" 2>/dev/null||echo ?)) — exiting." >&2; exit 1
fi
echo $$ > "$PID_FILE"

CONF_FILE="${CONF_FILE:-/etc/alwaysx11/alwaysx11.conf}"
# shellcheck source=/dev/null
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" || true

POLL_INTERVAL="${POLL_INTERVAL:-1}"
STABLE_SECONDS="${STABLE_SECONDS:-5}"
DRM_ROOT="${DRM_ROOT:-/sys/class/drm}"
DM_SERVICE="${DM_SERVICE:-}"
DUMMY_DISPLAY="${DUMMY_DISPLAY:-:1}"
DUMMY_XORG_CONF="${DUMMY_XORG_CONF:-/etc/alwaysx11/xorg-dummy.conf}"
VNC_ENABLE="${VNC_ENABLE:-false}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWD_FILE="${VNC_PASSWD_FILE:-/etc/alwaysx11/vncpasswd}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
LOG_TAG="alwaysx11"
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-15}"
XORG_BIN="${XORG_BIN:-/usr/bin/Xorg}"
DM_LIB="${DM_LIB:-/usr/local/lib/alwaysx11/dm-detect.sh}"

# ── Logging ───────────────────────────────────────────────────────────────────
declare -A _LL=([debug]=0 [info]=1 [warn]=2 [error]=3)
_min_ll="${_LL[${LOG_LEVEL:-info}]:-1}"
log() {
    local lv="${1:-info}"; shift; local msg="$*"
    (( ${_LL[$lv]:-1} < _min_ll )) && return 0 || true
    local ts; ts="$(date '+%F %T')"
    local line="$ts [$LOG_TAG][$lv] $msg"
    logger -t "$LOG_TAG" -- "[$lv] $msg" 2>/dev/null || true
    echo "$line"
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE" || true
}
logd() { log debug "$*"; }; logi() { log info "$*"; }
logw() { log warn  "$*"; }; loge() { log error "$*"; }

state_set() { echo "$1" > "$STATE_FILE"; }
state_get() { cat "$STATE_FILE" 2>/dev/null || echo "unknown"; }

# ── DM detection library ──────────────────────────────────────────────────────
if [[ -f "$DM_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$DM_LIB"
else
    _DM_CANDIDATES=(
        "gdm|GNOME/GDM" "gdm3|GNOME/GDM3" "sddm|KDE/SDDM"
        "lightdm|LightDM" "lxdm|LXDE/LXDM" "xdm|XDM" "slim|SLiM" "nodm|nodm"
    )
    DM_FOUND="false"; DM_NAME="none"

    dm_detect() {
        DM_FOUND="false"; DM_NAME="none"
        if [[ -n "${DM_SERVICE:-}" ]]; then
            if systemctl cat "${DM_SERVICE}.service" &>/dev/null \
               || systemctl cat "${DM_SERVICE}" &>/dev/null; then
                DM_NAME="custom/${DM_SERVICE}"; DM_FOUND="true"; return 0
            fi
            logw "Forced DM_SERVICE='${DM_SERVICE}' not found — auto-detecting"
            DM_SERVICE=""
        fi
        # FIX B8: init ALL label vars before loop — set -u safe
        local au="" eu="" iu="" al="" el="" il="" unit label st en
        for c in "${_DM_CANDIDATES[@]}"; do
            unit="${c%%|*}"; label="${c##*|}"
            systemctl cat "${unit}.service" &>/dev/null \
                || systemctl cat "${unit}" &>/dev/null || continue
            st=$(systemctl is-active  "${unit}" 2>/dev/null || echo "inactive")
            en=$(systemctl is-enabled "${unit}" 2>/dev/null || echo "disabled")
            [[ "$st" == "active"  && -z "$au" ]] && { au="$unit"; al="$label"; }
            [[ "$en" == "enabled" && -z "$eu" ]] && { eu="$unit"; el="$label"; }
            [[ -z "$iu" ]]                        && { iu="$unit"; il="$label"; }
        done
        if   [[ -n "$au" ]]; then DM_SERVICE="$au"; DM_NAME="$al"; DM_FOUND="true"
        elif [[ -n "$eu" ]]; then DM_SERVICE="$eu"; DM_NAME="$el"; DM_FOUND="true"
        elif [[ -n "$iu" ]]; then DM_SERVICE="$iu"; DM_NAME="$il"; DM_FOUND="true"
        else DM_SERVICE=""; DM_NAME="headless-only"; DM_FOUND="false"; fi
    }

    dm_is_active() {
        [[ -n "${DM_SERVICE:-}" ]] || return 1
        systemctl is-active --quiet "${DM_SERVICE}" 2>/dev/null
    }
    dm_start() {
        [[ -n "${DM_SERVICE:-}" ]] || return 1
        systemctl start "${DM_SERVICE}" 2>/dev/null || true
        local i=0 max=$(( WAIT_TIMEOUT_S * 2 ))
        while (( i < max )); do dm_is_active && return 0; sleep 0.5; i=$(( i+1 )); done
        return 1
    }
    dm_stop() {
        [[ -n "${DM_SERVICE:-}" ]] || return 0
        systemctl stop "${DM_SERVICE}" 2>/dev/null || true
        local i=0 max=$(( WAIT_TIMEOUT_S * 2 ))
        while (( i < max )); do dm_is_active || return 0; sleep 0.5; i=$(( i+1 )); done
        return 1
    }
fi

# ── HDMI detection ────────────────────────────────────────────────────────────
hdmi_connected() {
    local f val
    for f in "${DRM_ROOT}"/card*-HDMI-A-*/status; do
        [[ -f "$f" ]] || continue
        # FIX: pure bash read — no subshell, no tr
        read -r val < "$f" 2>/dev/null || continue
        [[ "$val" == "connected" ]] && return 0
    done
    return 1
}

# ── Free display finder ───────────────────────────────────────────────────────
# FIX B6: pure function, does NOT mutate DUMMY_DISPLAY global
_find_free_display() {
    local n="${1#:}"; [[ "$n" =~ ^[0-9]+$ ]] || n=1
    local tries=0
    while (( tries < 20 )); do
        [[ -e "/tmp/.X${n}-lock" || -S "/tmp/.X11-unix/X${n}" ]] \
            || { echo ":${n}"; return 0; }
        n=$(( n+1 )); tries=$(( tries+1 ))
    done
    echo ":${1#:}"
}

# ── Dummy Xorg ────────────────────────────────────────────────────────────────
dummy_start() {
    # FIX B6: resolve once, persist
    DUMMY_DISPLAY="$(_find_free_display "${DUMMY_DISPLAY}")"
    local n="${DUMMY_DISPLAY#:}"
    logi "Starting dummy Xorg on ${DUMMY_DISPLAY}"

    # Remove stale lock whose owner is dead
    local lock="/tmp/.X${n}-lock" sock="/tmp/.X11-unix/X${n}" op=""
    if [[ -f "$lock" ]]; then
        read -r op < "$lock" 2>/dev/null || op=""; op="${op// /}"
        if [[ -n "$op" ]] && ! kill -0 "$op" 2>/dev/null; then
            logd "Removing stale X lock $lock (PID $op gone)"; rm -f "$lock" "$sock"
        fi
    fi

    [[ -f "$DUMMY_XORG_CONF" ]] || { loge "Dummy Xorg config missing: $DUMMY_XORG_CONF"; return 1; }

    # FIX B4: ensure log dir exists
    local xlog="/var/log/alwaysx11/xorg-dummy.log"
    mkdir -p "$(dirname "$xlog")"

    "${XORG_BIN}" "${DUMMY_DISPLAY}" \
        -config "${DUMMY_XORG_CONF}" \
        -nolisten tcp \
        -logfile "${xlog}" \
        &>/dev/null &
    echo $! > "$DUMMY_PID_FILE"
    logd "Dummy Xorg PID=$(cat "$DUMMY_PID_FILE") on ${DUMMY_DISPLAY}"

    # FIX B3: poll X lock file — no xdpyinfo dep needed
    local i=0
    while (( i < 40 )); do
        [[ -e "/tmp/.X${n}-lock" ]] && { logi "Dummy Xorg ready on ${DUMMY_DISPLAY}"; break; }
        sleep 0.1; i=$(( i+1 ))
    done
    [[ -e "/tmp/.X${n}-lock" ]] || logw "Dummy Xorg: lock not found within 4s (may still be starting)"

    [[ "${VNC_ENABLE}" == "true" ]] && vnc_start || true
}

dummy_stop() {
    vnc_stop
    if [[ -f "$DUMMY_PID_FILE" ]]; then
        local pid; pid=$(cat "$DUMMY_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            logi "Stopping dummy Xorg PID=$pid"
            kill -TERM "$pid" 2>/dev/null || true
            local i=0
            while (( i < 40 )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$(( i+1 )); done
            kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }
        fi
        rm -f "$DUMMY_PID_FILE"
    fi
    local n="${DUMMY_DISPLAY#:}"
    rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null || true
}

dummy_is_running() {
    [[ -f "$DUMMY_PID_FILE" ]] || return 1
    local pid; pid=$(cat "$DUMMY_PID_FILE" 2>/dev/null || echo "")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── VNC ───────────────────────────────────────────────────────────────────────
vnc_start() {
    command -v x11vnc &>/dev/null || { logw "x11vnc not installed — skipping"; return 0; }
    mkdir -p /var/log/alwaysx11
    logi "Starting x11vnc on ${DUMMY_DISPLAY} port ${VNC_PORT}"
    # FIX B5: use -pidfile so we get the real x11vnc PID, not the shell bg PID
    local args=(-display "${DUMMY_DISPLAY}" -port "${VNC_PORT}"
                 -forever -shared -noxdamage -quiet
                 -o "/var/log/alwaysx11/x11vnc.log"
                 -pidfile "${VNC_PID_FILE}")
    [[ -f "${VNC_PASSWD_FILE}" ]] && args+=(-rfbauth "${VNC_PASSWD_FILE}") || args+=(-nopw)
    DISPLAY="${DUMMY_DISPLAY}" x11vnc "${args[@]}" &>/dev/null &
    sleep 0.5
    [[ -f "$VNC_PID_FILE" ]] \
        && logd "x11vnc running PID=$(cat "$VNC_PID_FILE")" \
        || logw "x11vnc did not write PID file"
}

vnc_stop() {
    if [[ -f "$VNC_PID_FILE" ]]; then
        local pid; pid=$(cat "$VNC_PID_FILE" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
        rm -f "$VNC_PID_FILE"
    fi
    pkill -f "x11vnc.*${DUMMY_DISPLAY}" 2>/dev/null || true
}

# ── Mode switching ─────────────────────────────────────────────────────────────
switch_to_display() {
    logi "── Switching → DISPLAY (${DM_NAME}) ──"
    state_set "switching_to_display"
    dummy_stop
    if [[ "${DM_FOUND}" == "true" ]]; then
        dm_start && logi "DM '${DM_NAME}' started" \
                 || logw "DM '${DM_NAME}' start timed out (it may still be coming up)"
    else
        # FIX B10: explicit message — no DM means no login screen
        logi "No DM installed. HDMI connected but no login manager will start."
        logi "Install a DM (e.g. apt install sddm) or connect via SSH."
    fi
    state_set "display"
    logi "── DISPLAY mode active ──"
}

switch_to_headless() {
    logi "── Switching → HEADLESS (dummy on ${DUMMY_DISPLAY}) ──"
    state_set "switching_to_headless"
    if [[ "${DM_FOUND}" == "true" ]] && dm_is_active; then
        dm_stop && logi "DM '${DM_NAME}' stopped" || logw "DM stop timed out"
    fi
    dummy_start && state_set "headless" || state_set "headless_error"
    logi "── HEADLESS mode active ──"
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
_cleanup() {
    logi "AlwaysX11 shutting down"
    dummy_stop
    rm -f "$PID_FILE" "$STATE_FILE"
    exit 0
}
trap _cleanup SIGTERM SIGINT SIGHUP

# ── Boot ──────────────────────────────────────────────────────────────────────
dm_detect
logi "══════════════════════════════════════════"
logi "AlwaysX11 v3"
logi "  DM:     ${DM_NAME} (unit: ${DM_SERVICE:-none})"
logi "  Poll:   ${POLL_INTERVAL}s | Stable: ${STABLE_SECONDS} ticks"
logi "  DRM:    ${DRM_ROOT}"
logi "  Dummy:  ${DUMMY_DISPLAY} | VNC: ${VNC_ENABLE}"
logi "══════════════════════════════════════════"

if hdmi_connected; then
    logi "HDMI present at boot → DISPLAY mode"
    switch_to_display
else
    logi "No HDMI at boot → HEADLESS mode"
    switch_to_headless
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
stable_count=0
last_target=""

while true; do
    hdmi_connected && target="display" || target="headless"

    if [[ "$target" != "$last_target" ]]; then
        stable_count=0; last_target="$target"
        logd "Change detected → target=${target} (need ${STABLE_SECONDS} stable ticks)"
    else
        # FIX B9: use $(( )) assignment not (( )) — safe under set -e when count is 0
        stable_count=$(( stable_count + 1 ))
    fi

    if (( stable_count >= STABLE_SECONDS )); then
        current="$(state_get)"
        need_switch=false
        [[ "$target" == "display"  && "$current" != "display"  ]] && need_switch=true
        [[ "$target" == "headless" && "$current" != "headless" \
           && "$current" != "headless_error" ]]                    && need_switch=true

        if $need_switch; then
            logi "Stable ${STABLE_SECONDS} ticks → ${current} → ${target}"
            [[ "$target" == "display" ]] && switch_to_display || switch_to_headless
            stable_count=0
        fi
    fi

    # Watchdog: resurrect dead dummy Xorg
    if [[ "$(state_get)" == "headless" ]] && ! dummy_is_running; then
        logw "Dummy Xorg died unexpectedly — restarting"
        dummy_start || loge "Watchdog restart failed"
    fi

    sleep "${POLL_INTERVAL}"
done
