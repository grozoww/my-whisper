#!/usr/bin/env bash
#
# Regenerates the screenshots in docs/images, the ones the README shows.
#
#   ./scripts/screenshots.sh              every shot the README uses
#   ./scripts/screenshots.sh home modes   just those
#
# How it works: the app is launched once per shot with OURWHISPER_SCREENSHOT set, which puts that
# screen on display with seeded demo data and prints its window number — see ScreenshotMode. This
# script then photographs that one window and kills the app.
#
# The app cannot take its own picture: screen recording is granted per bundle and a debug build's
# path changes with the checkout, so the freshly built app has been granted nothing. Your terminal
# has. If every shot comes out blank or black, that is the permission to give — System Settings ▸
# Privacy & Security ▸ Screen Recording — to whatever is running this script.
#
# Your own settings, modes and history are never in these pictures. Screenshot mode redirects the
# app's storage to a throwaway directory.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="OurWhisper"
CONFIG="Debug"
OUTPUT="docs/images"
# Wide enough to read on a README at full width, small enough not to bloat the repository.
WIDTH=1600

# The shots the README uses. A window shot is taken twice, once per theme; the pill is dark on
# transparency either way, so it is taken once.
WINDOW_SHOTS=(home modes history)
PILL_SHOTS=(pill.listening)

command -v screencapture >/dev/null || { echo "screencapture not found"; exit 1; }

# Same reasoning as run.sh: Xcode's default DerivedData, so the editor and this script look at the
# same build.
binary_path() {
  local dir
  dir="$(xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
  echo "$dir/$SCHEME.app/Contents/MacOS/$SCHEME"
}

echo "==> Building $SCHEME ($CONFIG)"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'platform=macOS' build \
  | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)' || true

BINARY="$(binary_path)"
[ -x "$BINARY" ] || { echo "No binary at $BINARY"; exit 1; }

mkdir -p "$OUTPUT"
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

# One shot: launch, wait for the window number, photograph it, kill the app.
shoot() {
  local target="$1" theme="$2" out="$3"
  local log="$LOGS/$(echo "$target-$theme" | tr '.' '-').log"
  local pid window=""

  OURWHISPER_SCREENSHOT="$target" OURWHISPER_SCREENSHOT_THEME="$theme" \
    "$BINARY" >"$log" 2>&1 &
  pid=$!

  for _ in $(seq 1 100); do
    if grep -q "SCREENSHOT READY" "$log" 2>/dev/null; then
      window="$(awk '/SCREENSHOT READY/{print $3; exit}' "$log")"
      break
    fi
    if grep -q "SCREENSHOT FAILED" "$log" 2>/dev/null; then break; fi
    sleep 0.2
  done

  if [ -z "$window" ]; then
    kill "$pid" 2>/dev/null || true
    echo "    failed: $(grep SCREENSHOT "$log" 2>/dev/null || echo "the app never reported a window")"
    return 1
  fi

  # -o drops the window shadow, which a README does not want baked into the image.
  screencapture -x -o -l"$window" "$out"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

resize() {
  local file="$1"
  sips --resampleWidth "$WIDTH" "$file" >/dev/null
}

selected=("$@")
wanted() {
  [ ${#selected[@]} -eq 0 ] && return 0
  local candidate
  for candidate in "${selected[@]}"; do [ "$candidate" = "$1" ] && return 0; done
  return 1
}

for shot in "${WINDOW_SHOTS[@]}"; do
  wanted "$shot" || continue
  for theme in light dark; do
    out="$OUTPUT/$shot-$theme.png"
    echo "==> $shot ($theme)"
    shoot "$shot" "$theme" "$out"
    resize "$out"
  done
done

for shot in "${PILL_SHOTS[@]}"; do
  wanted "$shot" || continue
  out="$OUTPUT/${shot/pill./pill-}.png"
  echo "==> $shot"
  shoot "$shot" dark "$out"
done

echo
echo "Wrote:"
ls -la "$OUTPUT"
