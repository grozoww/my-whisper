#!/usr/bin/env bash
#
# Builds, signs, notarizes and staples a distributable OurWhisper.dmg.
#
# Runs in CI (see .github/workflows/release.yml) and locally. Kept as a script rather than inline
# YAML so a release can be reproduced and debugged on a laptop.
#
# Required environment:
#   SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   APPLE_TEAM_ID      10-character team id
#   NOTARY_APPLE_ID    Apple ID for notarization
#   NOTARY_PASSWORD    app-specific password for that Apple ID

set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is required}"
: "${NOTARY_PASSWORD:?NOTARY_PASSWORD is required}"

APP_NAME="OurWhisper"
BUILD_DIR="build/release"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"

# MARKETING_VERSION in the project is the single source of truth for the version number.
VERSION="$(grep -m1 'MARKETING_VERSION' OurWhisper.xcodeproj/project.pbxproj | sed 's/.*= *//; s/;//')"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Building $APP_NAME $VERSION (Release)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

echo "==> Re-signing bundle with hardened runtime"
# --options runtime is mandatory: notarization rejects anything without the hardened runtime.
codesign --force --deep --timestamp \
  --options runtime \
  --entitlements "$APP_NAME.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"

codesign --verify --strict --verbose=2 "$APP"

echo "==> Building disk image"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Notarizing (this waits for Apple, typically 1-5 minutes)"
xcrun notarytool submit "$DMG" \
  --apple-id "$NOTARY_APPLE_ID" \
  --password "$NOTARY_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "✓ $DMG is signed, notarized and stapled."
spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
