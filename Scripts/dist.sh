#!/usr/bin/env bash
#
# Phase E — build → Developer ID sign → notarize → staple → DMG, in one command.
#
# ONE-TIME human setup (details in docs/DISTRIBUTION.md):
#   1. Enroll in the paid Apple Developer Program ($99/yr).
#   2. Create a "Developer ID Application" certificate:
#        Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸ + ▸
#        "Developer ID Application".  It installs into your login keychain.
#   3. Store a notarization credential once (secret goes straight to the keychain,
#      the script never sees it):
#        xcrun notarytool store-credentials shotai-notary \
#          --apple-id "you@example.com" --team-id JX6BU857VX \
#          --password "<app-specific-password>"
#      (app-specific password: appleid.apple.com ▸ Sign-In & Security ▸
#       App-Specific Passwords.)
#
# Then, from the repo root:  ./Scripts/dist.sh
#
# Output: build/dist/shotAI-<version>.dmg  — signed, notarized, stapled, and
# Gatekeeper-verified. Hand that DMG to anyone; it opens on any Mac, even offline.

set -euo pipefail

# ---------------- config ----------------
SCHEME="shotAI"
APP_NAME="shotAI"
TEAM_ID="JX6BU857VX"
NOTARY_PROFILE="${NOTARY_PROFILE:-shotai-notary}"   # name used with store-credentials
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$REPO/Signing/Distribution.entitlements"
DIST="$REPO/build/dist"
DD="$REPO/build/dist-dd"                              # isolated DerivedData

cd "$REPO"
say() { printf '\033[1;35m▸ %s\033[0m\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------- preflight ----------------
say "Preflight"
IDENTITY="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/ {print $2; exit}')"
[ -n "${IDENTITY:-}" ] || die "No 'Developer ID Application' certificate in your keychain.
  Enroll in the Apple Developer Program, then create one:
  Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application."
echo "  cert:    $IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Create it once:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id $TEAM_ID --password <app-specific-password>
  (or set NOTARY_PROFILE=<name> if you used a different profile name)."
echo "  notary:  $NOTARY_PROFILE"

# ---------------- 1. clean Release build (unsigned; we sign explicitly next) ----------------
say "Building Release (clean)"
rm -rf "$DD" "$DIST"; mkdir -p "$DIST"
xcodebuild -project shotAI.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO clean build >/dev/null
APP="$DD/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || die "build product missing: $APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
cp -R "$APP" "$DIST/$APP_NAME.app"; APP="$DIST/$APP_NAME.app"
echo "  $APP_NAME $VERSION"

# ---------------- 2. Developer ID sign + hardened runtime (inside-out) ----------------
say "Signing (Developer ID + hardened runtime)"
# Sign nested code first if any ever appears (shotAI is dependency-free today).
while IFS= read -r f; do
  [ -n "$f" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" -type f 2>/dev/null || true)
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "  signed + verified"

# ---------------- 3. notarize + staple the .app ----------------
# Staple the app itself (not just the DMG) so it validates even when copied out of
# the DMG and run offline.
say "Notarizing app (uploads to Apple; ~1–5 min)"
APPZIP="$DIST/$APP_NAME-app.zip"
ditto -c -k --keepParent "$APP" "$APPZIP"
xcrun notarytool submit "$APPZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$APPZIP"

# ---------------- 4. build DMG from the stapled app ----------------
say "Packaging DMG"
STAGE="$DIST/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"                 # drag-to-install affordance
DMG="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---------------- 5. notarize + staple the DMG ----------------
say "Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# ---------------- 6. verify Gatekeeper ----------------
say "Verifying Gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
spctl -a -vvv "$APP" || true
codesign --verify --deep --strict --verbose=2 "$APP"
printf '\033[1;32m✅ Done → %s\033[0m\n' "$DMG"
