#!/bin/sh
# Fabrique les médias du mode démo (Demo/media, servis par Git LFS, hors du build) :
# la bande originale d'Elephants Dream (Jan Morgenstern, download.blender.org/ED) et des morceaux
# de Kevin MacLeod (incompetech.com), tous sous licence CC BY. Voir CREDITS.md.
# Usage : ./make-assets.sh <dossier des MP3 téléchargés>
set -eu
SRC=${1:?dossier source}; OUT="$(cd "$(dirname "$0")" && pwd)/media"; mkdir -p "$OUT"
cd "$SRC"
# Les identifiants doivent suivre ceux de Shared/API/Demo.swift.
ED=a0000000-0000-4000-8000-000000000001 COMEDY=a0000000-0000-4000-8000-000000000002 SUSPENSE=a0000000-0000-4000-8000-000000000003
JAN=b0000000-0000-4000-8000-000000000001 KEVIN=b0000000-0000-4000-8000-000000000002
n=1; for f in 1-TheWires 2-TypewriterDance 3-TheSafestPlace 4-EmoCreates 5-EndTitle 6-TeaserMusic 7-Ambience; do
  ffmpeg -v error -y -i $f.mp3 -map 0:a -c:a libmp3lame -b:a 128k -map_metadata -1 "$OUT/ed-$n.mp3"; n=$((n+1)); done
n=1; for f in sneaky-snitch monkeys-spinning-monkeys fluffing-a-duck carefree local-forecast---elevator cool-vibes funkorama; do
  ffmpeg -v error -y -i km-$f.mp3 -map 0:a -c:a libmp3lame -b:a 128k -map_metadata -1 "$OUT/comedy-$n.mp3"; n=$((n+1)); done
n=1; for f in investigations wallpaper darkest-child hitman lightless-dawn; do
  ffmpeg -v error -y -i km-$f.mp3 -map 0:a -c:a libmp3lame -b:a 128k -map_metadata -1 "$OUT/suspense-$n.mp3"; n=$((n+1)); done
# Pochettes : le recto du livret d'Elephants Dream, les sélections de Kevin MacLeod dessinées.
ffmpeg -v error -y -i ed-cover.jpg -vf "crop=ih:ih:0:0,scale=1000:1000" -q:v 3 "$OUT/cover-$ED.jpg"
ffmpeg -v error -y -i ed-cover.jpg -vf "crop=ih*0.55:ih*0.55:ih*0.05:ih*0.42,scale=1000:1000" -q:v 3 "$OUT/artist-$JAN.jpg"
art() { swift "$(dirname "$OUT")/art.swift" "$OUT/$1.jpg" "$2" "$3" "$4" "$5"; }
art cover-$COMEDY ff9f1c e71d36 "Comédies" 120
art cover-$SUSPENSE 1b263b 6a4c93 "Suspense" 120
art artist-$KEVIN 2ec4b6 3a86ff "KM" 300
ls -la "$OUT"; du -sh "$OUT"
