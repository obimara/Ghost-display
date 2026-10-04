#!/usr/bin/env bash
# Check public launcher validation, installed library lookup and subprocess budget.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Reproduce the X11-only installed layout without touching system directories.
install -Dm755 "$ROOT/scripts/ghost-display-x11.sh" "$TMP/bin/ghost-display-x11"
install -Dm644 "$ROOT/lib/monitor-profile.sh" "$TMP/lib/ghost-display-x11/monitor-profile.sh"
"$TMP/bin/ghost-display-x11" --dry-run >"$TMP/plan"
grep -q 'framebuffer=3840x1080' "$TMP/plan"

for setting in GHOST_MONITORS=65 GHOST_DPI=0 GHOST_DPI=10001 GHOST_LAYOUT=diagonal \
    GHOST_MAX_WIDTH=0 GHOST_MONITOR_SPECS=100x100, GHOST_SCALE=0.00001 \
    GHOST_MONITOR_SPECS=100x100,,200x200 GHOST_MONITOR_SPECS=100x100@99999999999999999999; do
    status=0
    env "$setting" "$TMP/bin/ghost-display-x11" --dry-run >"$TMP/error" 2>&1 || status=$?
    [[ "$status" == 2 ]] || { echo "Invalid profile accepted: $setting (status $status)" >&2; exit 1; }
done

# Keep the default geometry on one awk validation plus one calculation per monitor.
export PROFILE_REAL_AWK
PROFILE_REAL_AWK=$(command -v awk)
export PROFILE_AWK_CALLS="$TMP/awk-calls"
cat >"$TMP/bin/awk" <<'MOCK'
#!/usr/bin/env bash
printf 'awk\n' >>"$PROFILE_AWK_CALLS"
exec "$PROFILE_REAL_AWK" "$@"
MOCK
chmod +x "$TMP/bin/awk"
PATH="$TMP/bin:$PATH" "$TMP/bin/ghost-display-x11" --dry-run >"$TMP/plan"
[[ $(wc -l <"$PROFILE_AWK_CALLS") == 3 ]]
printf 'Shared profile validation, installed layout and subprocess checks passed.\n'
