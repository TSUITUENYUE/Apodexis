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

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
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

# Ad-hoc signing keeps the bundle internally consistent without requiring a
# Developer ID certificate. It does not notarize the app or bypass Gatekeeper.
codesign --force --deep --sign - --timestamp=none "$APP_PATH"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

echo "Created $DMG_PATH"
