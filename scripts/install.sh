#!/usr/bin/env bash
#
# Installs OurWhisper from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/grozoww/my-whisper/main/scripts/install.sh | bash
#
# Options, when running the script from a checkout rather than a pipe:
#
#   --version v0.2.0   install a particular release instead of the newest one
#   --prefix DIR       install somewhere other than /Applications
#   --no-open          install but do not launch
#
# Why this exists rather than "download the DMG and drag it across":
#
# There is no paid Apple Developer account behind this project, so releases are signed with a
# certificate of the project's own rather than notarized. macOS attaches `com.apple.quarantine` to
# anything downloaded by a browser, and for a build Apple has not vouched for it then refuses to
# open it at all — the dialog says the app "is damaged", which is both alarming and untrue.
# Removing that flag is the one manual step every user would otherwise have to be talked through,
# so the script does it and says so.
#
# It also clears a dead Accessibility grant, which is the other step people used to have to be
# talked through. See "Accessibility" below.
#
# The trade you are making by running this is the ordinary one for unnotarized software: you are
# trusting the publisher of this repository instead of Apple's review. Read the script first if
# that matters to you — that is why it is short, and why it is served from the same repository as
# the source it installs.

set -euo pipefail

REPO="grozoww/my-whisper"
APP_NAME="OurWhisper"
PREFIX="/Applications"
VERSION=""
OPEN_AFTER=true

# Written out rather than read back out of "$0": piped to bash, "$0" is "bash", and printing the
# usage would fail with a confusing error about a missing file.
usage() {
  cat <<'USAGE'
Installs OurWhisper from the latest GitHub release.

  curl -fsSL https://raw.githubusercontent.com/grozoww/my-whisper/main/scripts/install.sh | bash

Options (pass them after `bash -s --` when piping):

  --version v0.2.0   install a particular release instead of the newest one
  --prefix DIR       install somewhere other than /Applications
  --no-open          install but do not launch

Releases are signed but not notarized, because there is no paid Apple Developer account behind
this project. macOS refuses to open such a download at all, claiming the app is damaged, until the
quarantine flag is cleared — which is the step this script exists to do.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a tag, e.g. v0.2.0}"; shift 2 ;;
    --prefix)  PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --no-open) OPEN_AFTER=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# MARK: - Preflight
#
# Checked before anything is downloaded, so a machine that cannot run the app is told why instead
# of spending two minutes fetching 100 MB it will not be able to open.

[ "$(uname -s)" = "Darwin" ] || die "OurWhisper is a macOS app."

[ "$(uname -m)" = "arm64" ] || die "OurWhisper needs Apple Silicon. Speech runs on the Neural Engine, which Intel Macs do not have."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 15 ] || die "OurWhisper needs macOS 15 or later. This Mac is on $(sw_vers -productVersion)."

command -v curl >/dev/null 2>&1 || die "curl is required."

# MARK: - Find the download
#
# Not /releases/latest: that endpoint skips prereleases, and answers 404 rather than nothing when
# every release is one — which is the state this project was in for its whole life, and it is what
# made the app's update check go quiet. Asking for the list and taking the newest release that
# actually carries a DMG cannot fail that way, whatever the flags on any one release say.

if [ -n "$VERSION" ]; then
  API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
  API="https://api.github.com/repos/$REPO/releases?per_page=20"
fi

step "Looking up the latest release"
RELEASES="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")" \
  || die "Could not reach the GitHub releases API. Check your connection, or download the DMG by hand from https://github.com/$REPO/releases"

# GitHub returns releases newest first, so the first DMG in the response is the newest one. Parsed
# with grep rather than jq because jq is not on a stock Mac and this script must run on one.
# `|| true` because finding nothing is a normal outcome that the next line reports properly.
# Without it, `set -e` and `pipefail` between them kill the script on the empty grep and the user
# is left with a bare exit code and no idea why.
DMG_URL="$(printf '%s' "$RELEASES" \
  | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.dmg"' \
  | head -1 \
  | sed 's/.*"\(https[^"]*\)".*/\1/' || true)"

[ -n "$DMG_URL" ] || die "No DMG found in the releases for $REPO${VERSION:+ at $VERSION}. See https://github.com/$REPO/releases"

# Older releases predate the checksum file, so its absence is not an error.
SUMS_URL="$(printf '%s' "$RELEASES" \
  | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*/SHA256SUMS"' \
  | head -1 \
  | sed 's/.*"\(https[^"]*\)".*/\1/' || true)"

DMG_FILE="$(basename "$DMG_URL")"

# MARK: - Download

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Downloading $DMG_FILE"
curl -fL --progress-bar "$DMG_URL" -o "$WORK/$DMG_FILE" || die "Download failed."

if [ -n "$SUMS_URL" ]; then
  step "Checking the download"
  # Verified against a file from the same server, so this is not a signature — it catches a
  # truncated or corrupted download, which is the failure that actually happens on a 100 MB file.
  if curl -fsSL "$SUMS_URL" -o "$WORK/SHA256SUMS"; then
    EXPECTED="$(grep -F "$DMG_FILE" "$WORK/SHA256SUMS" | awk '{print $1}' | head -1 || true)"
    ACTUAL="$(shasum -a 256 "$WORK/$DMG_FILE" | awk '{print $1}')"
    if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
      die "Checksum mismatch. Expected $EXPECTED, got $ACTUAL. The download is corrupt — try again."
    fi
  fi
fi

# MARK: - Install

DEST="$PREFIX/$APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  step "Quitting the running copy"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && die "$APP_NAME is still running. Quit it from the menu bar and run this again."
fi

step "Mounting $DMG_FILE"
MOUNT="$(hdiutil attach "$WORK/$DMG_FILE" -nobrowse -readonly -mountrandom /tmp \
  | grep -o '/tmp/[^[:space:]]*$' | tail -1 || true)"
[ -n "$MOUNT" ] && [ -d "$MOUNT/$APP_NAME.app" ] || die "The disk image did not contain $APP_NAME.app."

mkdir -p "$PREFIX" 2>/dev/null || true
[ -w "$PREFIX" ] || die "$PREFIX is not writable by this account. Re-run with --prefix \"\$HOME/Applications\"."

# MARK: - Accessibility
#
# Read before the old bundle is deleted, because it cannot be read afterwards. macOS records the
# Accessibility grant against the *designated requirement* of the signature that was installed
# when the user granted it. If the incoming build has a different one, that grant is already dead
# — System Settings goes on showing a ticked OurWhisper that applies to nothing, which is the
# single most confusing way this app has ever failed. Comparing the two is what tells us whether
# it happened, and `-r-` writes to stderr, and comments the line out when the requirement is
# implicit, which is why both are handled here.
requirement_of() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'
}

OLD_REQUIREMENT=""
[ -d "$DEST" ] && OLD_REQUIREMENT="$(requirement_of "$DEST" || true)"

# Replaced rather than merged. Copying over an existing bundle leaves files from the old version
# behind inside it, and a code signature covering files that are no longer supposed to be there
# fails to validate.
step "Installing to $DEST"
rm -rf "$DEST"
ditto "$MOUNT/$APP_NAME.app" "$DEST"

# Only when it actually changed. Resetting unconditionally would take a working permission away
# from everyone who reinstalls, which is a worse bug than the one this fixes.
NEW_REQUIREMENT="$(requirement_of "$DEST" || true)"
if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]; then
  step "Clearing the Accessibility permission granted to the old build"
  echo "    Its signature changed, so macOS no longer applies that grant to this build."
  echo "    You will be asked for Accessibility once more, and this should be the last time."
  # No sudo: tccutil resets an app's own entry for the logged-in user. A failure here is not fatal
  # — the app's Home screen offers the same reset, and says how to do it by hand.
  tccutil reset Accessibility com.grozoww.ourwhisper >/dev/null 2>&1 || true
fi

hdiutil detach "$MOUNT" -quiet
MOUNT=""

# The whole reason this script exists. Without it macOS reports an ad-hoc signed download as
# damaged and offers only "Move to Trash".
step "Clearing the download quarantine flag"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "✓ $APP_NAME is installed at $DEST"
echo
echo "  It is a menu bar app — no Dock icon, no window at startup. Look for the microphone"
echo "  glyph in the menu bar."
echo
echo "  On first run it asks for two permissions, and needs both:"
echo "    Microphone      to hear you"
echo "    Accessibility   to watch for the hotkey and paste into the focused field"
echo
echo "  Accessibility survives updates: releases are signed with a certificate that does not"
echo "  change between versions, which is what macOS ties the permission to. If dictation ever"
echo "  stops after an upgrade anyway, the Home screen has a 'Reset and ask again' button."
echo

if [ "$OPEN_AFTER" = true ]; then
  step "Opening $APP_NAME"
  open "$DEST"
fi
