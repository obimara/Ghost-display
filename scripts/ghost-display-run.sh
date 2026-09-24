#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ghost-display-run [--display DISPLAY] COMMAND [ARG...]

Runs a command on the managed Ghost-display X server (default: :20).
The command replaces this wrapper, so signals and its exit status are preserved.
USAGE
}

display="${GHOST_DISPLAY:-:${GHOST_DISPLAY_NUM:-20}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)
      [[ $# -ge 2 ]] || { echo "--display requires a value" >&2; exit 2; }
      display="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
export DISPLAY="${display}"
exec "$@"
