#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOST_SCRIPT="${GHOST_SCRIPT:-${ROOT_DIR}/scripts/ghost-display-x11.sh}"

profiles=(
    "balanced-dual|GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 GHOST_DPI=96|Baseline dual 1080p; best default for RustDesk."
    "scaled-dual|GHOST_MONITORS=2 GHOST_RESOLUTION=1920x1080 GHOST_SCALE=1.25 GHOST_DPI=110|More workspace; higher encode and bandwidth cost."
    "mixed-workspace|GHOST_MONITOR_SPECS=1920x1080@1,2560x1440@1 GHOST_DPI=110|One detailed monitor; close cost to scaled dual."
    "vertical-triple|GHOST_MONITORS=3 GHOST_RESOLUTION=1280x720 GHOST_LAYOUT=vertical GHOST_DPI=96|Three compact panes; lowest pixel cost."
)

profile_stats() {
    local env_string="$1"
    local output framebuffer width height pixels mib
    read -r -a env_parts <<<"${env_string}"
    output="$(env "${env_parts[@]}" "${GHOST_SCRIPT}" --dry-run)"
    framebuffer="$(awk -F= '/framebuffer=/ { print $2 }' <<<"${output}")"
    width="${framebuffer%x*}"
    height="${framebuffer#*x}"
    pixels=$((width * height))
    mib="$(awk -v p="${pixels}" 'BEGIN { printf "%.1f", (p * 4) / 1048576 }')"
    printf '%s|%s|%s\n' "${framebuffer}" "${pixels}" "${mib}"
}

first_rest="${profiles[0]#*|}"
baseline_stats="$(profile_stats "${first_rest%%|*}")"
baseline_mib="$(cut -d'|' -f3 <<<"${baseline_stats}")"

printf '%-16s %-13s %9s %9s %9s  %s\n' "Profile" "Framebuffer" "MP" "MiB" "ΔMiB" "Context"
printf '%-16s %-13s %9s %9s %9s  %s\n' "-------" "-----------" "--" "---" "----" "-------"

for entry in "${profiles[@]}"; do
    name="${entry%%|*}"
    rest="${entry#*|}"
    env_string="${rest%%|*}"
    context="${rest#*|}"
    stats="$(profile_stats "${env_string}")"
    framebuffer="$(cut -d'|' -f1 <<<"${stats}")"
    pixels="$(cut -d'|' -f2 <<<"${stats}")"
    mib="$(cut -d'|' -f3 <<<"${stats}")"
    mp="$(awk -v p="${pixels}" 'BEGIN { printf "%.2f", p / 1000000 }')"
    delta_mib="$(awk -v m="${mib}" -v b="${baseline_mib}" 'BEGIN { printf "%+.1f", m - b }')"
    printf '%-16s %-13s %9s %9s %9s  %s\n' "${name}" "${framebuffer}" "${mp}" "${mib}" "${delta_mib}" "${context}"
done

cat <<'NOTE'

Result:
  Use balanced-dual as the finished profile unless the workflow needs extra
  space. It keeps dual-monitor semantics, matches common 1080p HDMI, and avoids
  the ~+9 MiB framebuffer jump of scaled or mixed high-detail profiles.
NOTE
