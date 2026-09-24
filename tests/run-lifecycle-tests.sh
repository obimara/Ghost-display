#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  if [[ -f "${TMP_DIR}/child" ]]; then
    kill "$(cat "${TMP_DIR}/child")" 2>/dev/null || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT
mkdir "${TMP_DIR}/bin"
touch "${TMP_DIR}/xorg.conf"
cat >"${TMP_DIR}/bin/Xorg" <<'MOCK'
#!/usr/bin/env bash
[[ "${FAIL_START:-0}" == 1 ]] && exit 7
printf '%s\n' "$$" >"${TEST_DIR}/child"
exec sleep 60
MOCK
cat >"${TMP_DIR}/bin/xset" <<'MOCK'
#!/usr/bin/env bash
[[ "${READY_ALWAYS:-0}" == 1 ]] && exit 0
[[ -f "${TEST_DIR}/child" ]] && kill -0 "$(cat "${TEST_DIR}/child")" 2>/dev/null
MOCK
cat >"${TMP_DIR}/bin/xrandr" <<'MOCK'
#!/usr/bin/env bash
[[ "${FAIL_CONFIG:-0}" == 1 ]] && exit 7
exit 0
MOCK
cat >"${TMP_DIR}/bin/xrdb" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
MOCK
chmod +x "${TMP_DIR}/bin/"*
export PATH="${TMP_DIR}/bin:${PATH}" TEST_DIR="${TMP_DIR}"
export XDG_RUNTIME_DIR="${TMP_DIR}" GHOST_XORG_CONFIG="${TMP_DIR}/xorg.conf"
SCRIPT="${ROOT_DIR}/scripts/ghost-display-x11.sh"
assert_clean() {
  [[ ! -f "${TMP_DIR}/ghost-display-20.pid" ]] || { echo 'PID file leaked' >&2; exit 1; }
  if [[ -f "${TMP_DIR}/child" ]]; then
    if kill -0 "$(cat "${TMP_DIR}/child")" 2>/dev/null; then
      echo 'Xorg child leaked' >&2
      exit 1
    fi
    rm "${TMP_DIR}/child"
  fi
}
if FAIL_START=1 bash "${SCRIPT}" --foreground >"${TMP_DIR}/out" 2>&1; then
  echo 'Failed Xorg startup unexpectedly succeeded' >&2; exit 1
fi
assert_clean
if FAIL_CONFIG=1 bash "${SCRIPT}" >"${TMP_DIR}/out" 2>&1; then
  echo 'Failed monitor configuration unexpectedly succeeded' >&2; exit 1
fi
assert_clean
if READY_ALWAYS=1 bash "${SCRIPT}" --foreground >"${TMP_DIR}/out" 2>&1; then
  echo 'Foreground launch adopted an unowned server' >&2; exit 1
fi
assert_clean
bash "${SCRIPT}" --foreground >"${TMP_DIR}/out" 2>&1 &
launcher=$!
for _ in {1..100}; do
  if grep -q 'RustDesk should' "${TMP_DIR}/out"; then break; fi
  sleep 0.05
done
grep -q 'RustDesk should' "${TMP_DIR}/out"
kill -TERM "${launcher}"
status=0
wait "${launcher}" || status=$?
[[ "${status}" == 143 ]] || { echo "Unexpected signal exit: ${status}" >&2; exit 1; }
assert_clean
bash "${SCRIPT}" >"${TMP_DIR}/out" 2>&1
kill -0 "$(cat "${TMP_DIR}/child")"
kill "$(cat "${TMP_DIR}/child")"
printf 'Xorg lifecycle checks passed.\n'
