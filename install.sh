#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="ghost-display-x11.service"
START_SERVICE=1
INSTALL_DEPS=1

usage() {
    cat <<'USAGE'
Usage: sudo ./install.sh [--no-start] [--no-deps]

Installs Ghost-display dependencies, Xorg config, runtime script, RustDesk
auto-display wrapper, profile tool, and systemd service. Pass GHOST_* variables with sudo -E to persist a custom
systemd profile, for example:

  GHOST_RESOLUTION=2560x1440 GHOST_DPI=120 sudo -E ./install.sh
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-start)
            START_SERVICE=0
            shift
            ;;
        --no-deps)
            INSTALL_DEPS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run as root: sudo ./install.sh" >&2
        exit 1
    fi
}

install_deps() {
    if [[ "${INSTALL_DEPS}" != "1" ]]; then
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "apt-get not found; install Xorg dependencies manually." >&2
        return
    fi

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes \
        xserver-xorg-core \
        xserver-xorg-video-dummy \
        x11-xserver-utils \
        x11-utils
}

install_files() {
    install -D -m 0644 "${ROOT_DIR}/config/20-ghost-display.conf" /etc/X11/ghost-display.conf
    install -D -m 0755 "${ROOT_DIR}/scripts/ghost-display-x11.sh" /usr/local/bin/ghost-display-x11
    install -D -m 0755 "${ROOT_DIR}/scripts/compare-ghost-profiles.sh" /usr/local/bin/compare-ghost-profiles
    install -D -m 0755 "${ROOT_DIR}/scripts/debug-ghost-display.sh" /usr/local/bin/ghost-display-debug
    install -D -m 0755 "${ROOT_DIR}/scripts/rustdesk-auto-display.sh" /usr/local/bin/rustdesk-auto-display
    install -D -m 0644 "${ROOT_DIR}/systemd/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
}

systemd_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    value="${value//$'\n'/\\n}"
    printf '%s' "${value}"
}

write_profile_dropin() {
    local keys=(
        GHOST_DISPLAY_NUM
        GHOST_DISPLAY
        GHOST_MONITORS
        GHOST_RESOLUTION
        GHOST_SCALE
        GHOST_DPI
        GHOST_LAYOUT
        GHOST_NAME_PREFIX
        GHOST_MONITOR_SPECS
        GHOST_XORG_LOG
        GHOST_MAX_WIDTH
        GHOST_MAX_HEIGHT
    )
    local key wrote=0
    local dropin_dir="/etc/systemd/system/${SERVICE_NAME}.d"
    local dropin_file="${dropin_dir}/profile.conf"

    for key in "${keys[@]}"; do
        if [[ -v ${key} ]]; then
            wrote=1
            break
        fi
    done

    if [[ "${wrote}" != "1" ]]; then
        return
    fi

    install -d -m 0755 "${dropin_dir}"
    {
        echo "[Service]"
        for key in "${keys[@]}"; do
            if [[ -v ${key} ]]; then
                printf 'Environment="%s=%s"\n' "${key}" "$(systemd_escape "${!key}")"
            fi
        done
    } >"${dropin_file}"
}

activate_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl not found; start manually with: /usr/local/bin/ghost-display-x11" >&2
        return
    fi

    if [[ ! -d /run/systemd/system ]]; then
        echo "systemd is not active; start manually with: /usr/local/bin/ghost-display-x11" >&2
        return
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"

    if [[ "${START_SERVICE}" == "1" ]]; then
        systemctl restart "${SERVICE_NAME}"
    fi
}

print_done() {
    echo "Ghost-display installed."
    echo "Config: /etc/X11/ghost-display.conf"
    echo "Runtime: /usr/local/bin/ghost-display-x11"
    echo "Compare: /usr/local/bin/compare-ghost-profiles"
    echo "Debug: /usr/local/bin/ghost-display-debug"
    echo "RustDesk auto display: /usr/local/bin/rustdesk-auto-display"
    echo "Service: ${SERVICE_NAME}"
    echo "Verify: DISPLAY=:20 xrandr --listmonitors"
    echo "Run RustDesk with: rustdesk-auto-display"
}

main() {
    require_root
    install_deps
    install_files
    write_profile_dropin
    /usr/local/bin/ghost-display-x11 --dry-run
    activate_service
    print_done
}

main "$@"
