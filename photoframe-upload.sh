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

usage() {
  echo "Usage: $0 <image-file> <device-ip> [width] [height]"
  echo "   or: $0 <image-file> --file <output-path> [width] [height]"
  echo "  e.g.: $0 photo.jpg 192.168.1.220 1200 1600"
  echo "  e.g.: $0 photo.jpg --file /var/www/smalldisplay/image-seeedframe.png"
  echo "  Tune saturation with an env var, e.g.: SATURATION=200 $0 photo.jpg 192.168.1.220"
  echo "  Tune the pink/purple-showing-as-white fix: PINK_FIX=0.4 $0 ...   or   PINK_FIX=0 $0 ... to disable"
  echo "  Tune/disable contrast stretch: CONTRAST_STRETCH=2% $0 ...   or   NORMALIZE=0 $0 ..."
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

INPUT="$1"
shift

OUTPUT_FILE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --file requires a path argument"
        exit 1
      fi
      OUTPUT_FILE="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -n "$OUTPUT_FILE" ]; then
  WIDTH="${POSITIONAL[0]:-1200}"
  HEIGHT="${POSITIONAL[1]:-1600}"
else
  if [ "${#POSITIONAL[@]}" -lt 1 ]; then
    usage
    exit 1
  fi
  DEVICE_IP="${POSITIONAL[0]}"
  WIDTH="${POSITIONAL[1]:-1200}"
  HEIGHT="${POSITIONAL[2]:-1600}"
fi

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

# This panel's "red" is a fairly dark, muted maroon, not a vivid red — so any
# bright pink/magenta is numerically closer to white than to that dark red,
# and gets dithered to white instead. PINK_FIX pulls brightness down, but only
# on saturated/colorful pixels (weighted by how saturated each pixel already
# is) — true whites and grays (saturation ≈ 0) are left untouched, unlike a
# flat brightness cut which dims everything including real whites to gray.
# 0 = off. Try 0.3-0.4 if pinks/purples are washing out to white on the panel.
PINK_FIX="${PINK_FIX:-0.4}"

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

echo "3/6  Boosting saturation (${SATURATION}%) and applying pink/purple fix (${PINK_FIX})..."
if [ "$PINK_FIX" = "0" ]; then
  convert "$WORKDIR/normalized.png" -modulate 100,"${SATURATION}",100 "$WORKDIR/saturated.png"
else
  convert "$WORKDIR/normalized.png" -modulate 100,"${SATURATION}",100 \
    -colorspace HSB -channel B -fx "b - ${PINK_FIX}*g" +channel -colorspace sRGB \
    "$WORKDIR/saturated.png"
fi

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

if [ -n "$OUTPUT_FILE" ]; then
  cp "$WORKDIR/output.png" "$OUTPUT_FILE"
  echo "Wrote converted image to ${OUTPUT_FILE}"
  echo "Done."
  exit 0
fi

echo "Uploading to http://${DEVICE_IP}/api/display-image ..."
CURL_ERR="$WORKDIR/curl_error.log"
set +e
HTTP_CODE=$(curl -sS -o "$WORKDIR/response.json" -w "%{http_code}" \
  --connect-timeout 5 --max-time 90 \
  -X POST -H "Content-Type: image/png" \
  --data-binary "@$WORKDIR/output.png" \
  "http://${DEVICE_IP}/api/display-image" 2>"$CURL_ERR")
CURL_EXIT=$?
set -e

if [ $CURL_EXIT -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "ERROR: curl failed (exit code ${CURL_EXIT}) talking to ${DEVICE_IP}."
  echo "curl said: $(cat "$CURL_ERR" 2>/dev/null)"
  if [ "$CURL_EXIT" = "28" ]; then
    echo "(That's a timeout — the device may have still received and is displaying the"
    echo " image even though it didn't reply in time. Worth checking the screen before"
    echo " assuming this actually failed.)"
  fi
  exit 1
fi

echo "HTTP status: ${HTTP_CODE}"
echo "Response: $(cat "$WORKDIR/response.json" 2>/dev/null)"

if [ "$HTTP_CODE" != "200" ]; then
  echo "Upload failed."
  exit 1
fi
echo "Done."
