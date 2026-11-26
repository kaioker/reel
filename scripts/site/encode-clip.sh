#!/bin/zsh
# Turns a folder of transparent PNG frames (from record-window) into the website's transparent video clips:
#   <name>.mov   HEVC with alpha (Safari)
#   <name>.webm  VP9 with alpha (Chrome, Firefox, Edge)
#   <name>.png   the first frame, transparent (poster while the clip loads, and for reduced motion)
# The page picks .mov for Safari and .webm for everything else (see site.js).
#
#   scripts/site/encode-clip.sh <frames-folder> <out-folder/name> [crop w:h:x:y] [last-frame] [first-frame]
set -e
FRAMES=$1; OUT=$2; CROP=${3:--}; LAST=${4:-100000}; FIRST=${5:-1}
F=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
[[ -d "$FRAMES" && -n "$OUT" ]] || { echo "usage: encode-clip.sh <frames> <out/name> [crop] [last-frame]"; exit 2; }
CROPF="null"; [[ "$CROP" != - ]] && CROPF="crop=$CROP"
CHAIN="$CROPF,trim=end_frame=$((LAST - FIRST + 1)),scale=trunc(iw/2)*2:trunc(ih/2)*2"
IN=(-framerate 30 -start_number $FIRST -i "$FRAMES/f%05d.png")

$F -hide_banner -loglevel error -y "${IN[@]}" -vf "$CHAIN,format=bgra" \
  -c:v hevc_videotoolbox -alpha_quality 0.85 -b:v 3M -tag:v hvc1 -movflags +faststart -an "$OUT.mov"
$F -hide_banner -loglevel error -y "${IN[@]}" -vf "$CHAIN,format=yuva420p" \
  -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 30 -row-mt 1 -deadline good -cpu-used 2 -auto-alt-ref 0 -an "$OUT.webm"
$F -hide_banner -loglevel error -y "${IN[@]}" -vf "$CHAIN" -frames:v 1 "$OUT.png"
echo "$(basename "$OUT"): mov $(du -h "$OUT.mov" | cut -f1), webm $(du -h "$OUT.webm" | cut -f1), poster $(du -h "$OUT.png" | cut -f1)"
