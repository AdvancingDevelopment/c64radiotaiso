#!/bin/sh
# Headless VICE smoke test: autostart the PRG in warp mode, run a bounded
# number of cycles, dump a screenshot on exit (exit code 1 = cycle limit hit).
#   usage: boot_test.sh out.png [cycles] [prg] [extra x64sc args...]
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/boot.png}"
CYCLES="${2:-6000000}"
PRG="${3:-build/taiso.prg}"
shift 3 2>/dev/null || shift $#
x64sc -default -warp -sounddev dummy +confirmonexit -autostartprgmode 1 \
      -limitcycles "$CYCLES" -exitscreenshot "$OUT" "$@" "$PRG" >/dev/null 2>&1 || true
echo "screenshot: $OUT"
