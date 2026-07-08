#!/bin/bash
#
# photoframe-upload.sh — convert + upload an image to a Spectra-6 e-paper
# photo frame (Seeed reTerminal E1004 running aitjcize/esp32-photoframe),
# using ImageMagick only. No Node.js required.
#
# This replicates the core of the project's own process-cli conversion:
#   1. Auto-orient + crop-to-fill the target resolution ("cover" mode)
#   2. Floyd-Steinberg dither against the panel's *measured* (perceived)
#      6-color palette, so dithering decisions match what the panel
#      actually looks like, not the theoretical pure colors
#   3. Remap the dithered pixels to the *theoretical* pure RGB values
#      (0/255 combos) — this is the part that matters: the device's BMP
#      path does no conversion of its own, so pixels must already be
#      exactly one of the 6 palette colors or you get the striping mess
#      from earlier.
#   4. Write a 24-bit uncompressed BMP (54-byte header, BGR, bottom-up) —
#      verified byte-for-byte against the firmware's own BMP writer.
#
# NOT replicated here: the exposure/contrast/tone-curve step (defaults to
# neutral/no-op values anyway) and HEIC input support. If a photo still
# looks off after this, or you need HEIC, fall back to the project's own
# process-cli (Node-based) — it's the authoritative implementation.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <image-file> <device-ip> [width] [height]"
  echo "  e.g.: $0 photo.jpg 192.168.1.220 1200 1600"
  echo "  Tune saturation with an env var, e.g.: SATURATION=200 $0 photo.jpg 192.168.1.220"
  echo "  Tune/disable letterbox trim, e.g.: TRIM_FUZZ=5 $0 ...   or   TRIM=0 $0 ..."
  exit 1
fi

INPUT="$1"
DEVICE_IP="$2"
WIDTH="${3:-1200}"
HEIGHT="${4:-1600}"

if ! command -v convert >/dev/null 2>&1; then
  echo "ImageMagick not found. Install with: sudo apt install imagemagick"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Trim burned-in black letterbox/pillarbox bars before anything else, so they
# don't get counted as "content" by the aspect-ratio crop below. Uses the
# corner pixel color as the reference and strips any matching uniform border.
# CAVEAT: this can't tell burned-in black bars apart from a genuinely dark/
# black image edge (e.g. a night scene) — it just trims whatever uniform
# color band it finds. Real encoder-burned bars are near-perfectly flat black,
# so a low fuzz tolerance (default 3%) should catch them while mostly leaving
# real dark photo edges alone, but set TRIM=0 to disable this step entirely
# if it ever clips something it shouldn't.
TRIM="${TRIM:-1}"
TRIM_FUZZ="${TRIM_FUZZ:-3}"

# How much to boost saturation before dithering. 100 = unchanged, 150 = +50%.
# E-paper panels render noticeably less vivid than their pure RGB values, so
# pushing saturation up here nudges borderline pixels toward the punchier
# palette colors instead of the muddier in-between ones during dithering.
SATURATION="${SATURATION:-160}"

# --- Spectra 6 palette (from the firmware's own calibration data) ---
# perceived = how each color actually looks on the panel (used for dithering)
# theoretical = the pure RGB value the device expects in the final pixels
PERCEIVED=(  "rgb(2,2,2)"     "rgb(190,200,200)" "rgb(205,202,0)" "rgb(135,19,0)" "rgb(5,64,158)"  "rgb(39,102,60)" )
THEORETICAL=("rgb(0,0,0)"     "rgb(255,255,255)" "rgb(255,255,0)" "rgb(255,0,0)"  "rgb(0,0,255)"   "rgb(0,255,0)"   )

if [ "$TRIM" = "1" ]; then
  echo "1/6  Trimming burned-in black letterbox/pillarbox bars (fuzz ${TRIM_FUZZ}%)..."
  convert "$INPUT" -auto-orient -fuzz "${TRIM_FUZZ}%" -trim +repage "$WORKDIR/trimmed.png"
else
  echo "1/6  Skipping letterbox trim (TRIM=0)..."
  convert "$INPUT" -auto-orient "$WORKDIR/trimmed.png"
fi

echo "2/6  Cropping/resizing to ${WIDTH}x${HEIGHT} (cover mode)..."
convert "$WORKDIR/trimmed.png" \
  -resize "${WIDTH}x${HEIGHT}^" \
  -gravity center -extent "${WIDTH}x${HEIGHT}" \
  "$WORKDIR/cover.png"

echo "3/6  Boosting saturation (${SATURATION}%)..."
convert "$WORKDIR/cover.png" -modulate 100,"${SATURATION}",100 "$WORKDIR/saturated.png"

echo "4/6  Building device palette swatch..."
convert "${PERCEIVED[@]/#/xc:}" +append "$WORKDIR/palette.png"

echo "5/6  Dithering (Floyd-Steinberg) against the panel's measured colors..."
convert "$WORKDIR/saturated.png" -dither FloydSteinberg -remap "$WORKDIR/palette.png" "$WORKDIR/dithered.png"

echo "6/6  Mapping to pure output colors and writing PNG..."
ARGS=()
for i in "${!PERCEIVED[@]}"; do
  ARGS+=(-fill "${THEORETICAL[$i]}" -opaque "${PERCEIVED[$i]}")
done
convert "$WORKDIR/dithered.png" -fuzz 0% "${ARGS[@]}" -type Palette "$WORKDIR/output.png"
# Note: PNG (not BMP) on purpose — the device caps uploads at 5MB, and an
# uncompressed 24-bit BMP at full panel resolution (1200x1600) is ~5.6MB,
# just over that limit. Since the image is already quantized to 6 flat
# colors at this point, PNG compresses it down to a couple hundred KB with
# no quality loss, comfortably under the cap.

echo "Uploading to http://${DEVICE_IP}/api/display-image ..."
HTTP_CODE=$(curl -s -o "$WORKDIR/response.json" -w "%{http_code}" \
  -X POST -H "Content-Type: image/png" \
  --data-binary "@$WORKDIR/output.png" \
  "http://${DEVICE_IP}/api/display-image")

echo "HTTP status: ${HTTP_CODE}"
echo "Response: $(cat "$WORKDIR/response.json")"

if [ "$HTTP_CODE" != "200" ]; then
  echo "Upload failed."
  exit 1
fi
echo "Done."
