#!/bin/sh
# tools/video.sh — turn a VICE movie recording into a YouTube-ready file.
#   usage: tools/video.sh in.mp4 [out.mp4] [start] [duration]
# VICE (Media > Record movie) writes the emulated screen at native size
# (384x247 NTSC, 384x272 PAL). YouTube re-encodes small videos into mush, so:
# nearest-neighbour 4x upscale (crisp pixels), letterbox to 1920x1080, H.264 +
# AAC, source frame rate kept (60 NTSC / 50 PAL). start/duration (seconds or
# hh:mm:ss) trim the clip. Needs ffmpeg + ffprobe.
set -e
IN="$1"; OUT="${2:-${1%.*}-youtube.mp4}"; START="${3:-0}"; DUR="$4"
[ -n "$IN" ] && [ -f "$IN" ] || { echo "usage: $0 in.mp4 [out.mp4] [start] [duration]"; exit 1; }
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")
if [ "$H" -gt 270 ]; then
  VF="crop=iw:270,scale=iw*4:ih*4:flags=neighbor"      # PAL: 270 x 4 = 1080
else
  VF="scale=iw*4:ih*4:flags=neighbor"                   # NTSC: 247 x 4 = 988, padded
fi
VF="$VF,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black"
if [ -n "$DUR" ]; then T="-t $DUR"; else T=""; fi
ffmpeg -loglevel error -y -ss "$START" $T -i "$IN" -vf "$VF" \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart "$OUT"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$OUT" | sed "s|^|$OUT: |"
