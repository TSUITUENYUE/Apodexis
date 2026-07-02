#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Apodexis"
SCHEME="Apodexis"
PROJECT="$ROOT_DIR/Apodexis.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/PackageDerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
STAGING_DIR="$DIST_DIR/dmg-root"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  if git -C "$ROOT_DIR" diff --quiet && git -C "$ROOT_DIR" diff --cached --quiet; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  fi
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || echo local)"
fi
VERSION="${VERSION#v}"

DMG_NAME="${DMG_NAME:-$APP_NAME-$VERSION-macOS.dmg}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$DMG_NAME"

rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR"
mkdir -p "$STAGING_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Signing $APP_NAME.app with an ad-hoc identity. This is for local testing only."
  codesign --force --deep --sign - --timestamp=none "$APP_PATH"
else
  echo "Signing $APP_NAME.app with Developer ID identity: $CODESIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$APP_PATH"
fi

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  echo "Signing DMG with Developer ID identity: $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "NOTARIZE=1 requires CODESIGN_IDENTITY to be a Developer ID Application certificate." >&2
    exit 1
  fi
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "NOTARIZE=1 requires APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD." >&2
    exit 1
  fi

  echo "Submitting DMG to Apple notarization service."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

  echo "Stapling notarization ticket to DMG."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

echo "Created $DMG_PATH"
