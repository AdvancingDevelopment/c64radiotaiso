#!/bin/sh
# Build the standard test variants and collect screenshots into build/test/.
# Each variant: name | acme defines | cycles | extra x64sc args
# NTSC is the default system (boot_test.sh); the PAL variants pass -pal.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/test
run() {
  name="$1"; defs="$2"; cycles="$3"; shift 3
  acme $defs --format cbm --outfile "build/test/$name.prg" src/main.asm 2>&1 | grep -v "Output file already chosen" || true
  ./test/boot_test.sh "build/test/$name.png" "$cycles" "build/test/$name.prg" "$@" >/dev/null
  sips --resampleWidth 768 "build/test/$name.png" --out "build/test/${name}_big.png" >/dev/null 2>&1
  echo "  $name -> build/test/${name}_big.png"
}
echo "== title / border / hud"
run title      ""                                            4000000
run title_pal  ""                                            4000000 -pal
run border     "-DTEST_BORDER=1"                             4000000 -pal
run hud        "-DTEST_PLAY=1 -DDEBUG_HUD=1"                 30000000
run hud_pal    "-DTEST_PLAY=1 -DDEBUG_HUD=1"                 30000000 -pal
run raster     "-DTEST_PLAY=1 -DRASTER_DEBUG=1"              8000000
echo "== movements (routine 1, signature phases)"
# slot starts: 128 384 640 896 1152 1408 1664 1920 2048 2304 2432 2688 2816
# poster phases (beats): 2.6 0.9 1.2 2.2 1.7 2.0 0.85 1.35 0.95 1.1 0.35 0.9 2.8
i=1
for t in 148 391 649 913 1165 1424 1670 1930 2055 2312 2434 2695 2838; do
  run "r1_m$i" "-DTEST_PLAY=1 -DTEST_TICK=$t -DTEST_FREEZE=1" 8000000
  i=$((i+1))
done
echo "== movements (routine 2)"
i=1
for t in 148 391 649 913 1165 1424 1670 1930 2055 2312 2434 2695 2838; do
  run "r2_m$i" "-DTEST_PLAY=2 -DTEST_TICK=$t -DTEST_FREEZE=1" 8000000
  i=$((i+1))
done
echo "== boundary crossing (free run from 8 ticks before movement 3), finish, PAL"
run boundary   "-DTEST_PLAY=1 -DTEST_TICK=376"               9000000
run finish     "-DTEST_PLAY=1 -DTEST_TICK=3068"              9000000
run pal_m5     "-DTEST_PLAY=1 -DTEST_TICK=1165 -DTEST_FREEZE=1" 8000000 -pal
echo "done: $(ls build/test/*_big.png | wc -l) screenshots"
