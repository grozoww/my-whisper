#!/usr/bin/env bash
#
# Builds a distributable OurWhisper.dmg.
#
# Two paths, and which one you get depends on whether you have a Developer ID certificate:
#
#   Signed and notarized — needs a paid Apple Developer account. Downloads open with a
#   double-click and no warning. This is what a release should be.
#
#   Ad-hoc signed — needs nothing. Produces a perfectly good DMG that Gatekeeper will refuse to
#   open on a first double-click, because Apple has not vouched for it. Users get past that with
#   right-click → Open, once. The script writes the exact wording to give them.
#
# Runs in CI (see .github/workflows/release.yml) and locally. Kept as a script rather than inline
# YAML so a release can be reproduced and debugged on a laptop.
#
#   ./scripts/package.sh              signed and notarized if the environment below is set,
#                                     otherwise ad-hoc
#   ./scripts/package.sh --unsigned   ad-hoc even when credentials are available
#
# Environment for the signed path:
#   SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   APPLE_TEAM_ID      10-character team id
#   NOTARY_APPLE_ID    Apple ID for notarization
#   NOTARY_PASSWORD    app-specific password for that Apple ID

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OurWhisper"
BUILD_DIR="build/release"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"

# MARKETING_VERSION in the project is the single source of truth for the version number.
VERSION="$(grep -m1 'MARKETING_VERSION' OurWhisper.xcodeproj/project.pbxproj | sed 's/.*= *//; s/;//')"

# Decide the path before building: the two produce different signatures, so this cannot be worked
# out afterwards.
NOTARIZE=true
if [ "${1:-}" = "--unsigned" ]; then
  NOTARIZE=false
elif [ -z "${SIGNING_IDENTITY:-}" ] || [ -z "${NOTARY_APPLE_ID:-}" ] || [ -z "${NOTARY_PASSWORD:-}" ]; then
  NOTARIZE=false
fi

if [ "$NOTARIZE" = true ]; then
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for a notarized build}"
  IDENTITY="$SIGNING_IDENTITY"
  DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
else
  # "-" is ad-hoc: a real signature with no certificate behind it. Preferred over no signature at
  # all, because macOS refuses to run an unsigned arm64 binary outright.
  IDENTITY="-"
  DMG="$DIST_DIR/$APP_NAME-$VERSION-unsigned.dmg"
  echo "==> No Developer ID credentials. Building an ad-hoc signed DMG."
  echo "    It will work, but Gatekeeper will warn on first open. See dist/INSTALL.md."
  echo
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Building $APP_NAME $VERSION (Release)"
BUILD_ARGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination 'platform=macOS'
  CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR"
  CODE_SIGN_STYLE=Manual
  # On the command line rather than only in the project, because Swift package targets live in a
  # generated project of their own and do not inherit ARCHS from ours. Without this the Release
  # build goes universal and fails compiling FluidAudio for x86_64 — a machine this app cannot run
  # on anyway.
  ARCHS=arm64
)

if [ "$NOTARIZE" = true ]; then
  BUILD_ARGS+=(
    CODE_SIGN_IDENTITY="$IDENTITY"
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  # The Release configuration names a Developer ID identity that does not exist here, so signing
  # is turned off for the build and done by hand below.
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${BUILD_ARGS[@]}" build

echo "==> Signing bundle with hardened runtime"
# --options runtime is mandatory for notarization, and harmless without it.
SIGN_ARGS=(--force --deep --options runtime --entitlements "$APP_NAME.entitlements" --sign "$IDENTITY")
# A timestamp needs Apple's timestamp server and a real certificate; an ad-hoc signature cannot
# carry one, and asking for it fails the build.
[ "$NOTARIZE" = true ] && SIGN_ARGS=(--timestamp "${SIGN_ARGS[@]}")

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building disk image"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
# The symlink is what makes the window a drag-to-install target rather than a puzzle.
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

if [ "$NOTARIZE" = true ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  echo "==> Notarizing (this waits for Apple, typically 1-5 minutes)"
  xcrun notarytool submit "$DMG" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "==> Stapling"
  # Stapling attaches the notarization ticket to the file, so it opens cleanly even offline.
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  echo
  echo "✓ $DMG is signed, notarized and stapled."
  spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
else
  # Written to a file rather than printed, so the release workflow can paste it into the release
  # notes verbatim. Someone who downloads an app that refuses to open and is given no explanation
  # concludes it is broken.
  cat > "$DIST_DIR/INSTALL.md" <<INSTALL
## Installing

1. Open the DMG and drag **OurWhisper** to Applications.
2. **Right-click OurWhisper in Applications and choose Open**, then confirm.

Step 2 is needed only the first time. A plain double-click will say the app "cannot be opened
because Apple cannot check it for malicious software" — that means this build is not notarized,
not that anything is wrong with it. Notarization needs a paid Apple Developer account.

If macOS refuses even after right-click → Open, clear the download quarantine flag:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/OurWhisper.app
\`\`\`

OurWhisper then asks for **Microphone** and **Accessibility** permission. Both are required:
the microphone to hear you, Accessibility to watch for the hotkey and paste into the focused
field. It is a menu bar app — look for the microphone icon in the menu bar, not the Dock.
INSTALL

  echo
  echo "✓ $DMG is built and ad-hoc signed."
  echo "  Not notarized, so Gatekeeper will warn on first open."
  echo "  Ship $DIST_DIR/INSTALL.md alongside it, or paste it into the release notes."
fi

ls -lh "$DIST_DIR"
