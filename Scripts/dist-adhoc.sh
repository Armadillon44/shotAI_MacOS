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
# Entra SSO config is baked in at build time from the gitignored
# shotAI/Resources/Federation.plist (#69). Which way this should go depends
# entirely on WHO the artifact is for, and getting it wrong is silent either way:
#
#   on  -> the config ships in the DMG, so staff sign in with their work account
#          and never see an API key. THIS IS THE CURRENT RELEASE SETTING: the
#          decision (docs/SSO-WIF.md) is one public download path for everyone,
#          accepting that the tenant and org identifiers are extractable from a
#          public artifact. Reconnaissance, not access — using them still needs
#          an Entra token from the tenant carrying the shotAI.User role.
#   off -> strips it. For an artifact that must not carry the identifiers at all,
#          which is what a second, external-only build would use if that trade is
#          ever revisited.
#
# Required explicitly, with no default, because both mistakes are invisible: a
# public DMG that leaks the config looks fine, and an internal DMG missing it
# just quietly shows everyone the API-key path.
FED="$BUILT/Contents/Resources/Federation.plist"
case "${SHOTAI_SSO:-}" in
  on)
    [ -f "$FED" ] || { echo "✗ SHOTAI_SSO=on but no shotAI/Resources/Federation.plist on this machine — the build has no SSO" >&2; exit 1; }
    echo "  SSO:        baked in — staff sign in with their work account" ;;
  off)
    rm -f "$FED"
    echo "  SSO:        stripped (PUBLIC build — bring-your-own-key)" ;;
  *)
    echo "✗ set SHOTAI_SSO=off for a public release, or SHOTAI_SSO=on for an internal build." >&2
    echo "  off strips the bundled Entra config; on requires it to be present." >&2
    exit 1 ;;
esac

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
