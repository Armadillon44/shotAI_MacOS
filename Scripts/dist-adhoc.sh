#!/usr/bin/env bash
# Ad-hoc release packaging — the interim path until Phase E (Developer ID +
# notarization, see Scripts/dist.sh + docs/DISTRIBUTION.md).
#
# Clean Release build (unsigned) -> ad-hoc codesign inside-out -> UDZO DMG with an
# /Applications symlink. Produces build/dist/shotAI-<version>.dmg.
#
# Ad-hoc signed means Gatekeeper blocks the first launch; release notes carry the
# `xattr -dr com.apple.quarantine /Applications/shotAI.app` workaround.
#
# Usage: bash Scripts/dist-adhoc.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="shotAI"; APP_NAME="shotAI"
DIST="$REPO/build/dist"; DD="$REPO/build/dist-dd"
cd "$REPO"

echo "▸ Clean Release build (unsigned)"
rm -rf "$DD"
xcodebuild -project shotAI.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO clean build >/dev/null
BUILT="$DD/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "✗ build product missing" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT/Contents/Info.plist")"
echo "  $APP_NAME $VERSION (build $BUILDNO)"

mkdir -p "$DIST"; APP="$DIST/$APP_NAME.app"; rm -rf "$APP"; cp -R "$BUILT" "$APP"

echo "▸ Ad-hoc sign (inside-out; no hardened runtime)"
while IFS= read -r f; do [ -n "$f" ] && codesign --force --sign - "$f"; done \
  < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" -type f 2>/dev/null || true)
codesign --force --sign - "$APP"
codesign --verify --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -iE "Signature|TeamId|flags" | sed 's/^/    /'

echo "▸ Package DMG"
STAGE="$DIST/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "  → $DMG"; ls -la "$DMG"
