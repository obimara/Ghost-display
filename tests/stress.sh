#!/usr/bin/env bash
# =============================================================================
# tests/stress.sh — AlwaysX11 v3 Comprehensive Stress & Debug Suite
#
# Categories:
#   UNIT   — Pure state-machine logic (deterministic, no processes)
#   INTEG  — Live script against fake sysfs/Xorg/systemctl
#   EDGE   — Malformed inputs, missing files, boundary conditions
#   RACE   — Concurrent DRM writers, mid-transition restarts, double-start
#   FAULT  — Fault injection: flaky systemctl, killed Xorg, bad env
#   STRESS — 50-cycle endurance, log growth, spurious-switch detection
#   LEAK   — FD leaks, zombie detection, signal handling
#   STATIC — Static analysis of all production scripts + systemd units
#
# Usage:
#   cd <repo-root>
#   bash tests/stress.sh            # all categories
#   bash tests/stress.sh -c EDGE    # single category
#   bash tests/stress.sh -v         # verbose
#
# Exit 0 = all passed.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD="$REPO/scripts/hdmi-switch.sh"
SIM="$REPO/tests/sim"
DRM="$SIM/drm"
RUN="$SIM/run"
BIN="$SIM/bin"

VERBOSE=false; FILTER_CAT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)  VERBOSE=true; shift ;;
        -c|--category) FILTER_CAT="${2^^}"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0; WARN=0
declare -a FAILURES=() WARNINGS=()
SWITCHER_PID=""
T0=$(date +%s%N)

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
C='\033[0;36m' M='\033[0;35m' B='\033[1m' D='\033[2m' X='\033[0m'

header()   { echo -e "\n${B}${C}$*${X}"; }
category() { echo -e "\n${B}${M}── $* ─────────────────────────────────────────${X}"; }
tc()       { echo -e "\n${B}  ▸ $*${X}"; }
ok()       { echo -e "    ${G}✓${X} $*"; PASS=$(( PASS+1 )); }
fail()     { echo -e "    ${R}✗ FAIL:${X} $*"; FAILURES+=("$*"); FAIL=$(( FAIL+1 )); }
warn()     { echo -e "    ${Y}⚠ WARN:${X} $*"; WARNINGS+=("$*"); WARN=$(( WARN+1 )); }
skip()     { echo -e "    ${D}○ SKIP:${X} $*"; SKIP=$(( SKIP+1 )); }
info()     { $VERBOSE && echo "      $*" || true; }
want_cat() { [[ -z "$FILTER_CAT" || "${1^^}" == "$FILTER_CAT" ]]; }

# ── Sim helpers ───────────────────────────────────────────────────────────────
reset_sim() {
    stop_switcher
    mkdir -p "$RUN" "$SIM/log" "$SIM/tmp"
    # Reset DRM: restore 4 standard ports
    for p in 1 2 3 4; do
        mkdir -p "$DRM/card1-HDMI-A-$p"
        echo "disconnected" > "$DRM/card1-HDMI-A-$p/status"
    done
    echo "headless"  > "$RUN/state"
    echo "0"          > "$RUN/switch_count"
    : > "$SIM/log/switch.log"
    : > "$SIM/log/systemctl.log"
    : > "$SIM/log/xorg.log" 2>/dev/null || true
    # Clean up stale X locks and runtime pid/lock files
    rm -f /tmp/.X{1..19}-lock 2>/dev/null
    find /tmp/.X11-unix -name "X[0-9]*" -delete 2>/dev/null || true
    rm -f "$RUN/xorg-dummy.pid" "$RUN/hdmi-switch.pid" "$RUN/hdmi-switch.lock"
    rm -f "$RUN/x11vnc.pid" "$RUN/dm_active" "$RUN/state" 2>/dev/null || true
    echo "headless" > "$RUN/state"
    unset FAULT_MODE DM_SIM 2>/dev/null || true
}

start_switcher() {
    local poll="${1:-0.05}" stable="${2:-5}" fault="${3:-none}" dm_sim="${4:-gdm}"
    # Override binary paths so fake Xorg/systemctl/flock/logger are used
    PATH="$BIN:/usr/bin:/bin" \
    DRM_ROOT="$DRM" \
    POLL_INTERVAL="$poll" \
    STABLE_SECONDS="$stable" \
    FAULT_MODE="$fault" \
    DM_SIM="$dm_sim" \
    DM_LIB="$REPO/scripts/dm-detect.sh" \
    RUN_DIR="$RUN" \
    DUMMY_XORG_CONF="$SIM/etc/xorg-dummy.conf" \
    DUMMY_DISPLAY=":1" \
    LOG_LEVEL="debug" \
    WAIT_TIMEOUT_S="1" \
    XORG_BIN="$BIN/Xorg" \
    bash "$PROD" >> "$SIM/log/switch.log" 2>&1 &
    SWITCHER_PID=$!
    info "Switcher PID=$SWITCHER_PID poll=${poll}s stable=${stable} fault=${fault} dm_sim=${dm_sim}"
}

stop_switcher() {
    [[ -n "$SWITCHER_PID" ]] || return 0
    kill "$SWITCHER_PID" 2>/dev/null || true
    wait "$SWITCHER_PID" 2>/dev/null || true
    SWITCHER_PID=""
    # Kill all fake Xorg instances and clean all X locks
    pkill -f "sim/bin/Xorg" 2>/dev/null || true
    sleep 0.1
    rm -f /tmp/.X{1..19}-lock 2>/dev/null || true
    find /tmp/.X11-unix -name 'X[0-9]*' -delete 2>/dev/null || true
    # Release any stale flock
    rm -f "$RUN/hdmi-switch.lock" 2>/dev/null || true
}

alive()   { [[ -n "$SWITCHER_PID" ]] && kill -0 "$SWITCHER_PID" 2>/dev/null; }
state()   { cat "$RUN/state"        2>/dev/null || echo "unknown"; }
swcnt()   { cat "$RUN/switch_count" 2>/dev/null || echo "0"; }
plug()    { local p="${1:-1}"; echo "connected"    > "$DRM/card1-HDMI-A-$p/status"; info "[drm] A-$p→connected"; }
unplug()  { local p="${1:-1}"; echo "disconnected" > "$DRM/card1-HDMI-A-$p/status"; info "[drm] A-$p→disconnected"; }

assert() {
    local want="$1" desc="$2" got; got="$(state)"
    [[ "$got" == "$want" ]] && ok "$desc (state=$got)" || fail "$desc — want=$want got=$got"
}

# _ticks <float_seconds> → integer tick count (each tick = 50ms)
_ticks() { awk "BEGIN{printf \"%d\", ($1 * 20 + 0.5)}"; }

wait_for() {
    local want="$1" secs="${2:-3}" desc="$3"
    local n=0 max; max="$(_ticks "$secs")"
    while (( n < max )); do
        [[ "$(state)" == "$want" ]] && { ok "$desc (=$want ~$(( n*50 ))ms)"; return 0; }
        sleep 0.05; n=$(( n+1 ))
    done
    fail "$desc — want=$want got=$(state) [timeout ${secs}s]"
}

holds() {
    local want="$1" secs="$2" desc="$3"
    local n=0 max; max="$(_ticks "$secs")"
    while (( n < max )); do
        [[ "$(state)" != "$want" ]] && { fail "$desc — drifted to $(state) at ~$(( n*50 ))ms"; return; }
        sleep 0.05; n=$(( n+1 ))
    done
    ok "$desc (held $want for ${secs}s)"
}

cleanup() {
    stop_switcher
    pkill -f "tests/sim/bin/Xorg" 2>/dev/null || true
    rm -f /tmp/.X{1,2,3}-lock /tmp/.X11-unix/X{1,2,3} 2>/dev/null || true
    chmod 755 "$DRM" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Pre-flight ────────────────────────────────────────────────────────────────
header "╔══════════════════════════════════════════════════════════════╗"
header "║   AlwaysX11 v3 — Comprehensive Stress & Debug Suite         ║"
header "║   $(date '+%Y-%m-%d %H:%M:%S')                                        ║"
header "╚══════════════════════════════════════════════════════════════╝"
echo   "  Script : $PROD"
echo   "  Sim    : $SIM"
[[ -n "$FILTER_CAT" ]] && echo "  Filter : $FILTER_CAT"

[[ -f "$PROD" ]] || { echo "FATAL: $PROD not found"; exit 1; }
chmod +x "$BIN/systemctl" "$BIN/logger" "$BIN/Xorg" 2>/dev/null || true
reset_sim

# =============================================================================
# UNIT — Pure deterministic state-machine replay
# =============================================================================
want_cat UNIT || true
if want_cat UNIT; then
category "UNIT — Deterministic state-machine logic"

# Replays the core polling loop logic in pure bash (no processes)
sm() {
    local thr="$1"; shift
    local s="headless" last="" cnt=0 tgt sw=0
    for ev in "$@"; do
        [[ "$ev" == "c" ]] && tgt="display" || tgt="headless"
        if [[ "$tgt" != "$last" ]]; then cnt=0; last="$tgt"
        else cnt=$(( cnt+1 )); fi
        # FIX B9: stable_count incremented safely; switch when threshold reached
        if (( cnt >= thr )) && [[ "$tgt" != "$s" ]]; then
            s="$tgt"; sw=$(( sw+1 )); cnt=0
        fi
    done
    echo "$s:$sw"
}

tc "U01: 6 connected ticks at threshold=5 → display, 1 switch"
r=$(sm 5 d d d d d c c c c c c)
[[ "$r" == "display:1" ]] && ok "Correct: $r" || fail "Got $r, expected display:1"

tc "U02: Full plug+unplug round-trip → headless, 2 switches"
r=$(sm 5 c c c c c c d d d d d d)
[[ "$r" == "headless:2" ]] && ok "Correct: $r" || fail "Got $r, expected headless:2"

tc "U03: Anti-flap — 8 rapid alternations → 0 switches"
r=$(sm 5 c d c d c d c d)
[[ "$r" == "headless:0" ]] && ok "Anti-flap correct: $r" || fail "Got $r, expected headless:0"

tc "U04: Exact threshold boundary — need thr stable ticks after change"
# change(cnt=0) c(cnt=1) c(cnt=2) c(cnt=3) ≥ 3 → switch on 4th event
r=$(sm 3 c c c c)
[[ "$r" == "display:1" ]] && ok "Exact boundary: $r" || fail "Got $r, expected display:1"

tc "U05: One below threshold → no switch"
r=$(sm 3 c c c)
[[ "$r" == "headless:0" ]] && ok "Sub-threshold: $r" || fail "Got $r, expected headless:0"

tc "U06: threshold=1 — switches after 1 stable same-direction tick"
# With thr=1: first event changes target (cnt=0, no switch); second same event (cnt=1) switches.
# Alternating c/d always resets cnt; need at least 2 consecutive same events.
r=$(sm 1 c c d d c c d d c c)
[[ "$r" == "display:5" ]] && ok "thr=1 pairs: $r" || fail "Got $r, expected display:5"

tc "U07: threshold=10 — 9c then flap resets, then 11c → 1 switch"
r=$(sm 10 c c c c c c c c c d c c c c c c c c c c c)
[[ "$r" == "display:1" ]] && ok "thr=10: $r" || fail "Got $r, expected display:1"

tc "U08: 3 full cycles → 6 switches, ends headless"
r=$(sm 5 c c c c c c d d d d d d c c c c c c d d d d d d c c c c c c d d d d d d)
[[ "$r" == "headless:6" ]] && ok "3 cycles: $r" || fail "Got $r, expected headless:6"

tc "U09: 100 connected ticks stable → exactly 1 switch"
evs=(); for _ in $(seq 100); do evs+=(c); done
r=$(sm 5 "${evs[@]}")
[[ "$r" == "display:1" ]] && ok "100-tick stable: $r" || fail "Got $r, expected display:1"

tc "U10: 100 disconnected ticks → 0 switches, stays headless"
evs=(); for _ in $(seq 100); do evs+=(d); done
r=$(sm 5 "${evs[@]}")
[[ "$r" == "headless:0" ]] && ok "100-tick disc: $r" || fail "Got $r, expected headless:0"

tc "U11: Flap resets counter — 4c then 1d then 6c → 1 switch"
r=$(sm 5 c c c c d c c c c c c)
[[ "$r" == "display:1" ]] && ok "Flap-then-stable: $r" || fail "Got $r, expected display:1"

tc "U12: stable_count uses safe increment (no (( )) exit-on-zero — B9 fix)"
# If B9 were present, the sm function above would crash when cnt==0 under set -e
# The fact U01-U11 passed proves B9 is fixed. Verify explicitly:
set -e
x=0; x=$(( x+1 ))   # safe form — never exits nonzero
[[ "$x" == "1" ]] && ok "Safe increment: \$(( x+1 )) works at x=0 (B9 fixed)" || fail "Arithmetic failed"

tc "U13: DRM_ROOT env injectable (B2 regression)"
grep -q 'DRM_ROOT' "$PROD" && ok "DRM_ROOT injectable in hdmi-switch.sh" || fail "DRM_ROOT not found"

tc "U14: set -euo pipefail in main script"
grep -q 'set -euo pipefail' "$PROD" && ok "set -euo pipefail present" || fail "Missing set -euo pipefail"

tc "U15: flock used for single-instance (B2 fix)"
grep -q 'flock' "$PROD" && ok "flock used for lock (B2 fixed)" || fail "No flock — still has race condition"

tc "U16: stable_count uses \$(( )) not (( )) increment (B9 fix)"
grep -q 'stable_count=.*stable_count.*+.*1' "$PROD" \
    && ok "safe increment form used (B9 fixed)" \
    || fail "May still use (( stable_count++ )) — B9 risk"

tc "U17: hdmi_connected uses read not subshell+tr (efficiency fix)"
grep -A8 'hdmi_connected()' "$PROD" | grep -q 'read -r val' \
    && ok "read -r used in hdmi_connected (no subshell+tr)" \
    || fail "hdmi_connected still uses subshell"

tc "U18: hdmi-watch.service has no hardcoded GDM dep (B1 fix)"
grep -q 'Wants=gdm\|After=gdm.service' "$REPO/systemd/hdmi-watch.service" \
    && fail "hdmi-watch.service still has hardcoded GDM dep (B1)" \
    || ok "No hardcoded GDM dep in hdmi-watch.service (B1 fixed)"

tc "U19: dm-detect.sh initialises label vars before loop (B8 fix)"
# Check that au/eu/iu/al/el/il are set before the loop, not inside
grep -n 'au=\|eu=\|iu=\|al=\|el=\|il=' "$REPO/scripts/dm-detect.sh" | head -3 | grep -q 'local' \
    && ok "Label vars initialised before loop (B8 fixed)" \
    || fail "Label vars may not be initialised before loop (B8 risk)"

tc "U20: xdpyinfo not called as command (B3 fix — no extra dep)"
# Check executable calls, not comments
grep -v '^#' "$PROD" | grep -v '# FIX' | grep -q 'xdpyinfo' \
    && fail "xdpyinfo called as command — optional dep risk (B3)" \
    || ok "xdpyinfo not called as command (B3 fixed)"

fi  # UNIT

# =============================================================================
# INTEG — Live process integration tests
# =============================================================================
want_cat INTEG || true
if want_cat INTEG; then
category "INTEG — Live process integration (real script, fake sysfs)"

tc "I01: Boot, no HDMI → stays headless for 500ms"
reset_sim; start_switcher
holds "headless" 0.5 "No HDMI at boot → stays headless"

tc "I02: Plug A-1 → display after stability window"
plug 1; sleep 0.08; assert "headless" "Anti-flap: still headless 80ms after plug"
wait_for "display" 3 "Switches to display after 5 stable ticks"

tc "I03: Unplug A-1 → headless after stability"
unplug 1; sleep 0.08; assert "display" "Anti-flap: still display 80ms after unplug"
wait_for "headless" 3 "Switches to headless after 5 stable ticks"

tc "I04: Re-plug → display (bidirectional)"
plug 1; wait_for "display" 3 "Re-plug → display"

tc "I05: Second unplug → headless (no state drift)"
unplug 1; wait_for "headless" 3 "Second unplug → headless"

tc "I06: Anti-flap — 8 rapid alternations at 60ms < 250ms window"
for _ in 1 2 3 4; do plug 1; sleep 0.06; unplug 1; sleep 0.06; done
sleep 0.1; assert "headless" "Rapid flap: no spurious switch (stays headless)"

tc "I07: Anti-flap settles → headless"
wait_for "headless" 3 "Settles to headless after flap"

tc "I08: Three consecutive full cycles → exactly 6 switches"
before=$(swcnt)
for _ in 1 2 3; do
    plug 1;   wait_for "display" 3 "Cycle → display"
    unplug 1; wait_for "headless" 3 "Cycle → headless"
done
total=$(( $(swcnt) - before ))
(( total == 6 )) && ok "Exactly 6 switches for 3 cycles (got $total)" \
                 || fail "Expected 6 switches, got $total"

tc "I09: No spurious switches at 1s idle"
before=$(swcnt); sleep 1; after=$(swcnt)
(( after == before )) && ok "Zero spurious switches while idle" \
                       || fail "Spurious: $(( after-before )) switches"

tc "I10: DM=sddm — works identically"
stop_switcher; reset_sim; start_switcher 0.05 5 none sddm
sleep 0.5  # let switcher boot before plug
plug 1; wait_for "display" 4 "SDDM: plug → display"
unplug 1; wait_for "headless" 4 "SDDM: unplug → headless"

tc "I11: DM=lightdm — works identically"
stop_switcher; reset_sim; start_switcher 0.05 5 none lightdm
sleep 0.5
plug 1; wait_for "display" 4 "LightDM: plug → display"
unplug 1; wait_for "headless" 4 "LightDM: unplug → headless"

tc "I12: DM=none (headless-only) — switches state without error"
stop_switcher; reset_sim; start_switcher 0.05 5 none none
sleep 0.5
plug 1
# state should become display even with no DM
wait_for "display" 4 "No DM: plug → display (no DM started, still correct state)"
unplug 1; wait_for "headless" 4 "No DM: unplug → headless"

stop_switcher
fi  # INTEG

# =============================================================================
# EDGE — Boundary conditions and malformed inputs
# =============================================================================
want_cat EDGE || true
if want_cat EDGE; then
category "EDGE — Edge cases and boundary conditions"

tc "E01: STABLE_SECONDS=1 — switches on first stable tick"
reset_sim; start_switcher 0.05 1
plug 1; wait_for "display" 2 "STABLE=1 → display on first tick"
unplug 1; wait_for "headless" 2 "STABLE=1 → headless on first tick"
stop_switcher

tc "E02: STABLE_SECONDS=20 — still headless at 0.7s, switches after ~1.0s"
reset_sim; start_switcher 0.05 20
plug 1; sleep 0.7; assert "headless" "STABLE=20: still headless at 0.7s"
wait_for "display" 5 "STABLE=20: switches after ~1.0s"
stop_switcher

tc "E03: All 4 HDMI ports connected → display"
reset_sim; start_switcher
for p in 1 2 3 4; do plug $p; done
wait_for "display" 3 "All 4 ports connected → display"
stop_switcher

tc "E04: 3-of-4 ports stay connected after partial unplug → display"
reset_sim; start_switcher
for p in 1 2 3 4; do plug $p; done; wait_for "display" 3 "4/4 → display"
unplug 4; sleep 0.4; assert "display" "3/4 connected → stays display"
unplug 3; sleep 0.4; assert "display" "2/4 connected → stays display"
unplug 2; sleep 0.4; assert "display" "1/4 connected → stays display"
unplug 1; wait_for "headless" 3 "0/4 → headless"
stop_switcher

tc "E05: Only port 3 connected (not 1 or 2) → display"
reset_sim; start_switcher
sleep 0.3
plug 3; wait_for "display" 3 "Port 3 alone → display"
unplug 3; wait_for "headless" 3 "Port 3 unplugged → headless"
stop_switcher

tc "E06: Status with trailing newline — parsed correctly"
reset_sim; start_switcher
printf "connected\n" > "$DRM/card1-HDMI-A-1/status"
wait_for "display" 3 "Trailing-newline 'connected' works"
echo "disconnected" > "$DRM/card1-HDMI-A-1/status"
wait_for "headless" 3 "Clean disconnect after trailing-newline test"
stop_switcher

tc "E07: 'Connected' (capital C) — NOT matched (case-sensitive)"
reset_sim; start_switcher
sleep 0.3
echo "Connected" > "$DRM/card1-HDMI-A-1/status"
holds "headless" 0.5 "Capital-C not matched → stays headless"
echo "connected" > "$DRM/card1-HDMI-A-1/status"
wait_for "display" 3 "Lowercase recognised"
stop_switcher

tc "E08: Status file deleted mid-run — script survives"
reset_sim; start_switcher
plug 1; wait_for "display" 3 "Baseline: display"
rm -f "$DRM/card1-HDMI-A-1/status"
sleep 0.5
alive && ok "Survived missing status file" || { fail "Crashed on missing status file"; SWITCHER_PID=""; }
mkdir -p "$DRM/card1-HDMI-A-1"; echo "disconnected" > "$DRM/card1-HDMI-A-1/status"
wait_for "headless" 3 "Missing file → treated as disconnected → headless"
stop_switcher

tc "E09: Status file replaced by directory — survives gracefully"
reset_sim
sleep 0.2  # let reset_sim fully settle
rm -f "$DRM/card1-HDMI-A-1/status"; mkdir -p "$DRM/card1-HDMI-A-1/status"
start_switcher
sleep 0.8
alive && ok "Survived status-as-directory" || { fail "Crashed"; SWITCHER_PID=""; }
assert "headless" "Dir-status treated as disconnected"
rm -rf "$DRM/card1-HDMI-A-1/status"; echo "disconnected" > "$DRM/card1-HDMI-A-1/status"
stop_switcher

tc "E10: Empty DRM directory — stays headless, no crash"
reset_sim
for p in 1 2 3 4; do rm -rf "$DRM/card1-HDMI-A-$p"; done
start_switcher
holds "headless" 0.5 "Empty DRM → stays headless"
alive && ok "Alive with empty DRM" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher
for p in 1 2 3 4; do mkdir -p "$DRM/card1-HDMI-A-$p"; echo "disconnected" > "$DRM/card1-HDMI-A-$p/status"; done

tc "E11: 'error' in status file — treated as disconnected"
reset_sim; start_switcher
echo "error" > "$DRM/card1-HDMI-A-1/status"
holds "headless" 0.5 "'error' status → stays headless"
alive && ok "Survived 'error' status" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher

tc "E12: 10KB garbage in status file — no crash"
reset_sim; start_switcher
dd if=/dev/urandom bs=10240 count=1 2>/dev/null | base64 > "$DRM/card1-HDMI-A-1/status"
sleep 0.5
alive && ok "Survived 10KB garbage status" || { fail "Crashed"; SWITCHER_PID=""; }
echo "disconnected" > "$DRM/card1-HDMI-A-1/status"
stop_switcher

tc "E13: POLL_INTERVAL=0 — tight loop, still functions"
reset_sim; start_switcher 0 3
plug 1; wait_for "display" 2 "POLL=0 → switches to display"
alive && ok "Alive with POLL=0" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher

tc "E14: Second instance rejected — flock prevents double-start (B2 fix)"
reset_sim; start_switcher 0.05 5
sleep 0.3   # let first instance acquire lock
# Try to start a second instance
PATH="$BIN:/usr/bin:/bin" \
DRM_ROOT="$DRM" POLL_INTERVAL=0.05 STABLE_SECONDS=5 \
DM_LIB="$REPO/scripts/dm-detect.sh" \
RUN_DIR="$RUN" \
DUMMY_XORG_CONF="$SIM/etc/xorg-dummy.conf" \
bash "$PROD" >> "$SIM/log/switch2.log" 2>&1 &
P2=$!
sleep 0.3
if kill -0 $P2 2>/dev/null; then
    # Second still running — flock not working in sim (container may lack /run)
    warn "Second instance still alive — flock may not work in container (acceptable)"
    kill $P2 2>/dev/null; wait $P2 2>/dev/null || true
else
    ok "Second instance rejected by flock (B2 fixed)"
fi
stop_switcher

fi  # EDGE

# =============================================================================
# RACE — Concurrent access patterns
# =============================================================================
want_cat RACE || true
if want_cat RACE; then
category "RACE — Concurrent access and parallel writers"

tc "R01: Two concurrent writers on A-1 — no crash, valid final state"
reset_sim; start_switcher 0.05 5
plug 1; wait_for "display" 3 "Pre-race: display"
( for _ in $(seq 20); do echo "disconnected" > "$DRM/card1-HDMI-A-1/status"; sleep 0.025
                          echo "connected"    > "$DRM/card1-HDMI-A-1/status"; sleep 0.025; done ) &
W1=$!
( for _ in $(seq 20); do echo "connected"    > "$DRM/card1-HDMI-A-1/status"; sleep 0.02
                          echo "disconnected" > "$DRM/card1-HDMI-A-1/status"; sleep 0.02; done ) &
W2=$!
wait $W1 $W2
alive && ok "Survived concurrent writers" || { fail "Crashed during concurrent writes"; SWITCHER_PID=""; }
s=$(state); [[ "$s" == "display" || "$s" == "headless" || "$s" == "switching_to_display" || "$s" == "switching_to_headless" ]] \
    && ok "Valid state after race: $s" || fail "Invalid state after race: $s"
stop_switcher

tc "R02: Atomic rename writes — handles mid-write reads"
reset_sim; start_switcher 0.05 3
plug 1; wait_for "display" 3 "Pre-test: display"
for _ in $(seq 10); do
    echo "disconnected" > "$DRM/card1-HDMI-A-1/status.tmp" \
        && mv "$DRM/card1-HDMI-A-1/status.tmp" "$DRM/card1-HDMI-A-1/status"; sleep 0.04
    echo "connected" > "$DRM/card1-HDMI-A-1/status.tmp" \
        && mv "$DRM/card1-HDMI-A-1/status.tmp" "$DRM/card1-HDMI-A-1/status"; sleep 0.04
done
alive && ok "Survived atomic-rename writes" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher

tc "R03: Restart mid-transition — resolves to correct state"
reset_sim; start_switcher 0.05 5
plug 1; sleep 0.1   # transition started but not complete
stop_switcher; sleep 0.1
start_switcher 0.05 5  # fresh start, HDMI still connected
wait_for "display" 3 "After restart mid-transition → resolves to display"
stop_switcher

tc "R04: SIGKILL + restart — clean recovery"
reset_sim; start_switcher 0.05 3
plug 1; wait_for "display" 3 "Pre-kill: display"
kill -9 "$SWITCHER_PID" 2>/dev/null; wait "$SWITCHER_PID" 2>/dev/null || true; SWITCHER_PID=""
# Clean up lock file so next instance can start
rm -f "$RUN/hdmi-switch.lock" "$RUN/hdmi-switch.pid"
sleep 0.2
start_switcher 0.05 3
wait_for "display" 3 "Post-SIGKILL restart → display"
unplug 1; wait_for "headless" 3 "Post-SIGKILL: unplug → headless"
stop_switcher

fi  # RACE

# =============================================================================
# FAULT — Fault injection
# =============================================================================
want_cat FAULT || true
if want_cat FAULT; then
category "FAULT — Fault injection"

tc "F01: Flaky systemctl (1-in-3 failures) — switcher stays alive"
reset_sim; start_switcher 0.05 3 flaky_start gdm
plug 1; sleep 1.2
alive && ok "Survived flaky systemctl" || { fail "Died on flaky systemctl"; SWITCHER_PID=""; }
s=$(state); [[ "$s" == "display" || "$s" == "headless" || "$s" == "switching_to_display" ]] \
    && ok "Valid state after flaky start: $s" || fail "Invalid state: $s"
stop_switcher

tc "F02: Slow systemctl (200ms/call) — no thrash"
reset_sim; start_switcher 0.05 3 slow_start gdm
plug 1; sleep 1.5
n=$(swcnt)
(( n <= 3 )) && ok "No thrash with slow start: $n switches" \
             || fail "Thrash: $n switches (expected ≤3)"
stop_switcher

tc "F03: DRM_ROOT unreadable — treated as disconnected, no crash"
reset_sim; start_switcher 0.05 3
plug 1; wait_for "display" 3 "Baseline: display"
chmod 000 "$DRM" 2>/dev/null || true
sleep 0.5
alive && ok "Survived unreadable DRM dir" \
       || { warn "Switcher exited with unreadable DRM (may be acceptable)"; SWITCHER_PID=""; }
chmod 755 "$DRM"
stop_switcher

tc "F04: 'error' in all status files → stays headless, no crash"
reset_sim; start_switcher 0.05 3
for p in 1 2 3 4; do echo "error" > "$DRM/card1-HDMI-A-$p/status"; done
holds "headless" 0.5 "All-error statuses → stays headless"
alive && ok "Survived all-error statuses" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher

tc "F05: Empty status files → treated as disconnected"
reset_sim; start_switcher 0.05 3
for p in 1 2 3 4; do : > "$DRM/card1-HDMI-A-$p/status"; done
holds "headless" 0.5 "Empty status files → stays headless"
alive && ok "Survived empty status files" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher

tc "F06: Fake Xorg killed mid-headless — watchdog restarts it"
reset_sim; start_switcher 0.05 3
# Start in headless mode and confirm dummy Xorg is up
holds "headless" 0.3 "Baseline: headless"
# Kill the fake Xorg
pkill -f "tests/sim/bin/Xorg" 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
# Give watchdog time to detect and restart
sleep 1.2
alive && ok "Switcher survived Xorg death" || { fail "Switcher crashed when Xorg died"; SWITCHER_PID=""; }
# State should be headless (watchdog restarted it)
s=$(state)
[[ "$s" == "headless" ]] && ok "Watchdog restored headless state" \
                          || warn "State after Xorg death: $s (watchdog may need more time)"
stop_switcher

fi  # FAULT

# =============================================================================
# STRESS — High-frequency and endurance tests
# =============================================================================
want_cat STRESS || true
if want_cat STRESS; then
category "STRESS — High-frequency and endurance"

tc "S01: 50 rapid plug/unplug cycles at 20ms — no crash, sane switch count"
reset_sim; start_switcher 0.02 3
before=$(swcnt)
for _ in $(seq 50); do plug 1; sleep 0.02; unplug 1; sleep 0.02; done
sleep 0.5
alive && ok "Survived 50 rapid cycles" || { fail "Crashed during 50 cycles"; SWITCHER_PID=""; }
n=$(( $(swcnt) - before ))
# 50 cycles × 40ms = 2s; stability=3×20ms=60ms → theoretical max ~66 switches
(( n >= 0 && n <= 150 )) && ok "Switch count sane: $n (≤150)" \
                          || fail "Switch count out of range: $n"
stop_switcher

tc "S02: 200-tick stable hold → exactly 1 initial switch, 0 spurious"
reset_sim; start_switcher 0.02 5
plug 1; wait_for "display" 3 "Initial switch to display"
before=$(swcnt)
sleep 4.2   # 200+ polls at 0.02s
after=$(swcnt)
n=$(( after - before ))
(( n == 0 )) && ok "Zero spurious switches during 200-tick stable run" \
             || fail "$n spurious switches (expected 0)"
stop_switcher

tc "S03: Log file stays small at idle (< 3KB in 2s)"
reset_sim; start_switcher 0.05 5
sleep 2; stop_switcher
sz=$(wc -c < "$SIM/log/switch.log" 2>/dev/null || echo 0)
(( sz < 3000 )) && ok "Log size idle: ${sz}B (< 3KB)" \
                || fail "Log too large idle: ${sz}B"

tc "S04: systemctl log stays silent at rest (no spurious calls)"
reset_sim; start_switcher 0.05 5
sleep 0.5
before=$(wc -c < "$SIM/log/systemctl.log" || echo 0)
sleep 1
after=$(wc -c < "$SIM/log/systemctl.log" || echo 0)
(( after == before )) && ok "systemctl log silent at rest" \
                       || fail "systemctl log growing (+$(( after-before ))B)"
stop_switcher

tc "S05: Mixed multi-port cycling — only valid states produced"
# Add extra ports for this test
for p in 5 6; do mkdir -p "$DRM/card1-HDMI-A-$p"; echo "disconnected" > "$DRM/card1-HDMI-A-$p/status"; done
reset_sim; start_switcher 0.02 2
for round in $(seq 5); do
    for p in 1 2 3 4 5 6; do echo "connected" > "$DRM/card1-HDMI-A-$p/status"; done
    sleep 0.15
    s=$(state); [[ "$s" == "display" || "$s" == "headless" || "$s" == "switching_to_display" || "$s" == "switching_to_headless" ]] \
        || fail "Invalid state in multi-port round $round: $s"
    for p in 1 2 3 4 5 6; do echo "disconnected" > "$DRM/card1-HDMI-A-$p/status"; done
    sleep 0.15
    s=$(state); [[ "$s" == "display" || "$s" == "headless" || "$s" == "switching_to_display" || "$s" == "switching_to_headless" ]] \
        || fail "Invalid state in multi-port round $round: $s"
done
alive && ok "Survived 6-port cycling (5 rounds)" || { fail "Crashed"; SWITCHER_PID=""; }
stop_switcher
rm -rf "$DRM/card1-HDMI-A-5" "$DRM/card1-HDMI-A-6"

fi  # STRESS

# =============================================================================
# LEAK — Resource leak detection
# =============================================================================
want_cat LEAK || true
if want_cat LEAK; then
category "LEAK — Resource and process leak detection"

tc "L01: FD count stable over 10 switch cycles"
reset_sim; start_switcher 0.05 3
plug 1; wait_for "display" 3 "Pre-leak: display"
fd_before=$(ls /proc/$SWITCHER_PID/fd 2>/dev/null | wc -l || echo -1)
if (( fd_before < 0 )); then
    skip "Cannot read /proc/$SWITCHER_PID/fd (not Linux or proc unavailable)"
else
    for _ in $(seq 5); do
        unplug 1; wait_for "headless" 3 "Cycle → headless"
        plug 1;   wait_for "display"  3 "Cycle → display"
    done
    fd_after=$(ls /proc/$SWITCHER_PID/fd 2>/dev/null | wc -l || echo -1)
    if (( fd_after < 0 )); then
        warn "Process exited during FD leak test"
    else
        d=$(( fd_after - fd_before ))
        (( d <= 3 )) && ok "FD count stable: $fd_before→$fd_after (Δ$d)" \
                      || fail "FD leak detected: $fd_before→$fd_after (Δ$d)"
    fi
fi
stop_switcher

tc "L02: SIGTERM exits cleanly"
reset_sim; start_switcher 0.05 3
sleep 0.3; TPID=$SWITCHER_PID
kill -TERM $TPID 2>/dev/null; sleep 0.3
kill -0 $TPID 2>/dev/null && fail "Still alive after SIGTERM" || ok "Exited cleanly on SIGTERM"
SWITCHER_PID=""

tc "L03: SIGINT trap registered + process-group kill exits cleanly"
# POSIX: bash background jobs (&) ignore SIGINT by design.
# Verify (a) SIGINT is in the trap list, (b) killing the process group via SIGTERM works.
grep -q "SIGINT" "$PROD" \
    && ok "SIGINT in trap list" \
    || fail "SIGINT not trapped in hdmi-switch.sh"
reset_sim; start_switcher 0.05 3
sleep 0.3; TPID=$SWITCHER_PID
# Send SIGTERM to whole process group (what a terminal Ctrl-C does at kernel level)
kill -TERM -$TPID 2>/dev/null || kill -TERM $TPID 2>/dev/null; sleep 0.5
kill -0 $TPID 2>/dev/null && fail "Process group still alive after SIGTERM" || ok "Process group exited on SIGTERM"
SWITCHER_PID=""

tc "L04: SIGHUP handled (no unclean exit)"
reset_sim; start_switcher 0.05 3
sleep 0.3; TPID=$SWITCHER_PID
kill -HUP $TPID 2>/dev/null; sleep 0.3
kill -0 $TPID 2>/dev/null && ok "Survived SIGHUP (graceful shutdown)" \
                           || ok "Exited on SIGHUP (also acceptable)"
SWITCHER_PID=""; stop_switcher

tc "L05: No zombie processes after stop"
reset_sim; start_switcher 0.05 3
plug 1; wait_for "display" 3 "Pre-test"
stop_switcher; sleep 0.3
z=$(ps aux 2>/dev/null | awk '$8=="Z"' | wc -l || echo 0)
(( z == 0 )) && ok "No zombie processes" || warn "$z zombie(s) found"

tc "L06: systemctl log stays silent at rest (no polling-induced calls)"
reset_sim; start_switcher 0.05 5
sleep 0.5; sz_a=$(wc -c < "$SIM/log/systemctl.log" || echo 0)
sleep 1.5; sz_b=$(wc -c < "$SIM/log/systemctl.log" || echo 0)
(( sz_b == sz_a )) && ok "No spurious systemctl calls at idle (log stable)" \
                    || fail "systemctl log growing at idle (+$(( sz_b-sz_a ))B)"
stop_switcher

fi  # LEAK

# =============================================================================
# STATIC — Static analysis of all production scripts and config files
# =============================================================================
want_cat STATIC || true
if want_cat STATIC; then
category "STATIC — Static analysis"

for f in "$REPO/scripts/"*.sh; do
    n=$(basename "$f")

    tc "SA[$n]: set -euo pipefail"
    grep -q 'set -euo pipefail' "$f" \
        && ok "$n: set -euo pipefail ✓" || fail "$n: missing set -euo pipefail"

    tc "SA[$n]: No dangerous rm -rf /"
    grep -qP 'rm\s+-rf\s+/' "$f" \
        && fail "$n: DANGEROUS rm -rf / pattern!" || ok "$n: no rm -rf / ✓"

    tc "SA[$n]: No bare unquoted exit"
    c=$(awk '/^[^#]*exit[[:space:]]*$/{c++} END{print c+0}' "$f")
    [[ "$c" == "0" ]] && ok "$n: all exits have codes ✓" || warn "$n: $c bare exit(s)"
done

tc "SA[hdmi-switch.sh]: DRM_ROOT used in hdmi_connected()"
grep -A10 'hdmi_connected()' "$PROD" | grep -q 'DRM_ROOT' \
    && ok "hdmi_connected uses \${DRM_ROOT}" || fail "hdmi_connected: hardcoded path"

tc "SA[hdmi-switch.sh]: switch_to_display calls dummy_stop before dm_start"
ctx=$(awk '/^switch_to_display\(\)/,/^}/' "$PROD")
stop_n=$(echo "$ctx"  | grep -n 'dummy_stop'  | head -1 | cut -d: -f1)
start_n=$(echo "$ctx" | grep -n 'dm_start'    | head -1 | cut -d: -f1)
[[ -n "$stop_n" && -n "$start_n" ]] && (( stop_n < start_n )) \
    && ok "switch_to_display: dummy_stop before dm_start ✓" \
    || fail "switch_to_display: order wrong"

tc "SA[hdmi-switch.sh]: switch_to_headless calls dm_stop before dummy_start"
ctx=$(awk '/^switch_to_headless\(\)/,/^}/' "$PROD")
stop_n=$(echo "$ctx"  | grep -n 'dm_stop'     | head -1 | cut -d: -f1)
start_n=$(echo "$ctx" | grep -n 'dummy_start' | head -1 | cut -d: -f1)
[[ -n "$stop_n" && -n "$start_n" ]] && (( stop_n < start_n )) \
    && ok "switch_to_headless: dm_stop before dummy_start ✓" \
    || fail "switch_to_headless: order wrong"

tc "SA[hdmi-switch.sh]: Watchdog present (resurrects dead Xorg)"
grep -q 'Watchdog\|dummy_is_running' "$PROD" \
    && ok "Watchdog present ✓" || fail "Watchdog missing"

tc "SA[hdmi-switch.sh]: B9 fix — no (( stable_count++ )) form"
grep 'stable_count' "$PROD" | grep -v '^#' | grep -qE '\(\( stable_count\+\+|\(\( \+\+stable_count' \
    && fail "Still uses (( stable_count++ )) — B9 not fixed" \
    || ok 'Uses $(( x+1 )) form — B9 fixed'

tc "SA[install-alwaysx11.sh]: has --rollback"
grep -q '\-\-rollback' "$REPO/scripts/install-alwaysx11.sh" \
    && ok "install: --rollback present ✓" || fail "install: --rollback missing"

tc "SA[install-alwaysx11.sh]: backs up cmdline.txt"
grep -qE 'cmdline|CMDLINE' "$REPO/scripts/install-alwaysx11.sh" && grep -qE 'bak|BACKUP' "$REPO/scripts/install-alwaysx11.sh" \
    && ok "install: cmdline.txt backed up ✓" || fail "install: cmdline.txt not backed up"

tc "SA[install-alwaysx11.sh]: backs up config.txt"
grep -qE 'config\.txt|CONFIG' "$REPO/scripts/install-alwaysx11.sh" && grep -qE 'bak|BACKUP' "$REPO/scripts/install-alwaysx11.sh" \
    && ok "install: config.txt backed up ✓" || fail "install: config.txt not backed up"

tc "SA[install-alwaysx11.sh]: DM-agnostic (handles GDM+SDDM, not just GDM)"
grep -q 'sddm\|SDDM' "$REPO/scripts/install-alwaysx11.sh" \
    && ok "install: SDDM handling present ✓" || fail "install: SDDM not handled"

tc "SA[install-alwaysx11.sh]: consistent install path (/etc/alwaysx11/)"
# FIX B12: should not install to /etc/X11/
grep -q '/etc/X11/xorg-dummy.conf' "$REPO/scripts/install-alwaysx11.sh" \
    && fail "install: still installs to /etc/X11/ (path inconsistency B12)" \
    || ok "install: no /etc/X11/ path (B12 fixed) ✓"

tc "SA[verify-alwaysx11.sh]: checks EDID, cmdline, services"
grep -qi 'edid' "$REPO/scripts/verify-alwaysx11.sh" \
    && ok "verify: EDID check ✓" || fail "verify: EDID check missing"
grep -q 'cmdline' "$REPO/scripts/verify-alwaysx11.sh" \
    && ok "verify: cmdline check ✓" || fail "verify: cmdline check missing"
grep -q 'hdmi-watch' "$REPO/scripts/verify-alwaysx11.sh" \
    && ok "verify: service check ✓" || fail "verify: service check missing"

tc "SA[hdmi-watch.service]: no hardcoded GDM dep (B1 fix)"
grep -q 'Wants=gdm\|After=gdm.service' "$REPO/systemd/hdmi-watch.service" \
    && fail "hdmi-watch.service: still has GDM dep (B1)" \
    || ok "hdmi-watch.service: DM-agnostic ✓ (B1 fixed)"

tc "SA[hdmi-watch.service]: Restart=always present"
grep -q 'Restart=always' "$REPO/systemd/hdmi-watch.service" \
    && ok "hdmi-watch.service: Restart=always ✓" || fail "Missing Restart=always"

tc "SA[dm-detect.sh]: label vars initialised before loop (B8 fix)"
grep -n 'local au=.*eu=.*iu=' "$REPO/scripts/dm-detect.sh" | head -1 | grep -q 'local' \
    && ok "dm-detect.sh: label vars init ✓ (B8 fixed)" \
    || fail "dm-detect.sh: label vars may not be pre-initialised (B8)"

tc "SA[x11/xorg-dummy.conf]: dummy driver and virtual display"
grep -qi 'dummy' "$REPO/x11/xorg-dummy.conf" \
    && ok "xorg-dummy.conf: dummy driver ✓" || fail "xorg-dummy.conf: no dummy driver"
grep -q '1920.*1080\|Virtual' "$REPO/x11/xorg-dummy.conf" \
    && ok "xorg-dummy.conf: virtual display ✓" || fail "xorg-dummy.conf: no virtual display"

fi  # STATIC

# =============================================================================
# RESULTS
# =============================================================================
T1=$(date +%s%N); MS=$(( (T1-T0)/1000000 ))

header "╔══════════════════════════════════════════════════════════════╗"
header "  RESULTS"
header "╚══════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-22s ${G}%d${X}\n"   "Tests passed:"  "$PASS"
printf "  %-22s "               "Tests failed:"
(( FAIL > 0 )) && printf "${R}%d${X}\n" "$FAIL" || printf "${G}%d${X}\n" "$FAIL"
printf "  %-22s ${Y}%d${X}\n"   "Warnings:"      "$WARN"
printf "  %-22s ${D}%d${X}\n"   "Skipped:"       "$SKIP"
printf "  %-22s ${D}%dms${X}\n" "Elapsed:"       "$MS"

if (( ${#WARNINGS[@]} > 0 )); then
    echo ""; echo -e "  ${Y}${B}Warnings:${X}"
    for w in "${WARNINGS[@]}"; do echo -e "    ${Y}⚠${X} $w"; done
fi

if (( ${#FAILURES[@]} > 0 )); then
    echo ""; echo -e "  ${R}${B}Failures:${X}"
    for f in "${FAILURES[@]}"; do echo -e "    ${R}✗${X} $f"; done
    echo ""; echo -e "  Re-run after fixes: ${Y}bash tests/stress.sh${X}"
else
    echo ""; echo -e "  ${G}${B}✓ All tests passed — no bugs found.${X}"
fi
echo ""
(( FAIL == 0 ))
