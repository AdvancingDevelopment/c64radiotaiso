#!/bin/sh
# Build the release kit into build/release/:
#   RadioTaiso64.prg, RadioTaiso64.d64, README.txt, FILE_ID.DIZ, screenshots/ (2x),
#   screenshots-native/ (384 px wide, for CSDb), cover-itch-630x500.png and
#   RadioTaiso64_v<version>.zip (prg + d64 + README + 2x screenshots), plus
#   RELEASE_NOTES.md (markdown body for the GitHub release, from release/NOTES.md).
# Screenshots come from headless VICE runs of the normal build (title, natural
# play runs, the finish screen after a full routine). Needs ffmpeg and zip.
#   usage: tools/release.sh [version]      (or: make release VERSION=1.0)
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-1.0}"
NAME="RadioTaiso64"
OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT/screenshots" "$OUT/screenshots-native"
make >/dev/null
make d64 >/dev/null 2>&1
cp build/taiso.prg "$OUT/$NAME.prg"
cp build/taiso.d64 "$OUT/$NAME.d64"
cp release/FILE_ID.DIZ "$OUT/FILE_ID.DIZ"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$(date +%Y-%m-%d)/g" release/README.txt > "$OUT/README.txt"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$(date +%Y-%m-%d)/g" release/NOTES.md > "$OUT/RELEASE_NOTES.md"

# shot <name> <acme defines> <cycles> [x64sc args]: native PNG + 2x nearest-neighbour PNG
shot() {
  name="$1"; defs="$2"; cycles="$3"; shift 3
  acme $defs --format cbm --outfile build/release_shot.prg src/main.asm 2>&1 | grep -v "already chosen" || true
  ./test/boot_test.sh "$OUT/screenshots-native/$name.png" "$cycles" build/release_shot.prg "$@" >/dev/null
  ffmpeg -loglevel error -y -i "$OUT/screenshots-native/$name.png" \
         -vf "scale=iw*2:ih*2:flags=neighbor" "$OUT/screenshots/$name.png"
  echo "  $name"
}
echo "screenshots:"
shot 01-title      ""              4000000
shot 02-title-pal  ""              4000000 -pal
shot 03-play-no1   "-DTEST_PLAY=1" 30000000
shot 04-play-no2   "-DTEST_PLAY=2" 100000000
shot 05-play-pal   "-DTEST_PLAY=1" 60000000 -pal
shot 06-finish     "-DTEST_PLAY=1" 205000000
rm -f build/release_shot.prg
# itch.io cover (630x500) cut from the 2x PAL title (768x544)
ffmpeg -loglevel error -y -i "$OUT/screenshots/02-title-pal.png" -vf "crop=630:500:69:10" \
       "$OUT/cover-itch-630x500.png"
(cd "$OUT" && rm -f "${NAME}_v${VERSION}.zip" && \
 zip -q -r "${NAME}_v${VERSION}.zip" "$NAME.prg" "$NAME.d64" README.txt FILE_ID.DIZ screenshots)
echo "release kit: $OUT"
ls -la "$OUT"
