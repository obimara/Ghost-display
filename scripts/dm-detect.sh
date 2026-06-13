#!/usr/bin/env bash
# dm-detect.sh — Display Manager detection library for AlwaysX11
set -euo pipefail
# Source this file then call dm_detect to populate DM_SERVICE, DM_NAME, DM_FOUND.
#
# Supports: GDM, GDM3, SDDM, LightDM, LXDM, XDM, SLiM, nodm, headless.
# Override: set DM_SERVICE=myunit before calling dm_detect.

_DM_CANDIDATES=(
    "gdm|GNOME/GDM"
    "gdm3|GNOME/GDM3"
    "sddm|KDE/SDDM"
    "lightdm|LightDM"
    "lxdm|LXDE/LXDM"
    "xdm|XDM"
    "slim|SLiM"
    "nodm|nodm"
)

dm_detect() {
    DM_FOUND="false"; DM_SERVICE="${DM_SERVICE:-}"; DM_NAME="none"

    if [[ -n "${DM_SERVICE:-}" ]]; then
        if systemctl cat "${DM_SERVICE}.service" &>/dev/null \
           || systemctl cat "${DM_SERVICE}" &>/dev/null; then
            DM_NAME="custom/${DM_SERVICE}"; DM_FOUND="true"; return 0
        fi
        echo "[dm-detect] WARNING: DM_SERVICE='${DM_SERVICE}' not found — auto-detecting" >&2
        DM_SERVICE=""
    fi

    # FIX B8: ALL label vars initialised before the loop so set -u is safe
    local au="" eu="" iu="" al="" el="" il=""
    local unit label st en

    for candidate in "${_DM_CANDIDATES[@]}"; do
        unit="${candidate%%|*}"; label="${candidate##*|}"
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
    [[ -n "${DM_SERVICE:-}" ]] || { echo "[dm-detect] No DM to start" >&2; return 1; }
    local timeout="${WAIT_TIMEOUT_S:-15}"
    systemctl start "${DM_SERVICE}" 2>/dev/null || true
    local i=0 max=$(( timeout * 2 ))
    while (( i < max )); do dm_is_active && return 0; sleep 0.5; i=$(( i+1 )); done
    return 1
}

dm_stop() {
    [[ -n "${DM_SERVICE:-}" ]] || return 0
    systemctl stop "${DM_SERVICE}" 2>/dev/null || true
    local timeout="${WAIT_TIMEOUT_S:-15}" i=0 max
    max=$(( timeout * 2 ))
    while (( i < max )); do dm_is_active || return 0; sleep 0.5; i=$(( i+1 )); done
    return 1
}

dm_unit() {
    local svc="${DM_SERVICE:-}"
    [[ "$svc" == *.service ]] && echo "$svc" || echo "${svc}.service"
}
