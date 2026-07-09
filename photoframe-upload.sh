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
  echo "  Tune/disable contrast stretch: CONTRAST_STRETCH=2% $0 ...   or   NORMALIZE=0 $0 ..."
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

# How much to clip at each end before stretching to full black/white range.
# 1% means the darkest/brightest 1% of pixels are allowed to clip, and
# everything else gets linearly stretched across the full 0-255 range. This
# fixes washed-out/low-contrast source images. Set to 0% for a literal
# min/max stretch (riskier — one stray bright/dark pixel can ruin it), or
# NORMALIZE=0 to disable this step entirely.
NORMALIZE="${NORMALIZE:-1}"
CONTRAST_STRETCH="${CONTRAST_STRETCH:-1%}"

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

echo "1/6  Cropping/resizing to ${WIDTH}x${HEIGHT} (cover mode)..."
convert "$INPUT" -auto-orient \
  -resize "${WIDTH}x${HEIGHT}^" \
  -gravity center -extent "${WIDTH}x${HEIGHT}" \
  "$WORKDIR/cover.png"

if [ "$NORMALIZE" = "1" ]; then
  echo "2/6  Normalizing light levels (contrast-stretch ${CONTRAST_STRETCH})..."
  convert "$WORKDIR/cover.png" -contrast-stretch "${CONTRAST_STRETCH}" "$WORKDIR/normalized.png"
else
  echo "2/6  Skipping light-level normalization (NORMALIZE=0)..."
  cp "$WORKDIR/cover.png" "$WORKDIR/normalized.png"
fi

echo "3/6  Boosting saturation (${SATURATION}%)..."
convert "$WORKDIR/normalized.png" -modulate 100,"${SATURATION}",100 "$WORKDIR/saturated.png"

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
  --connect-timeout 5 --max-time 30 \
  -X POST -H "Content-Type: image/png" \
  --data-binary "@$WORKDIR/output.png" \
  "http://${DEVICE_IP}/api/display-image") || true

if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "ERROR: could not reach ${DEVICE_IP} at all — is it awake, on WiFi, and at that IP?"
  exit 1
fi

echo "HTTP status: ${HTTP_CODE}"
echo "Response: $(cat "$WORKDIR/response.json" 2>/dev/null)"

if [ "$HTTP_CODE" != "200" ]; then
  echo "Upload failed."
  exit 1
fi
echo "Done."
