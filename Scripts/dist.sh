#!/usr/bin/env bash
#
# Phase E — build → Developer ID sign → notarize → staple → package, in one command.
#
#   ./Scripts/dist.sh              # DMG (hand distribution)   [default]
#   ./Scripts/dist.sh pkg          # signed .pkg (Intune / MDM)
#   ./Scripts/dist.sh all          # both
#
# ONE-TIME human setup (details in docs/DISTRIBUTION.md):
#   1. An Apple Developer Program membership (ideally LFI's org account).
#   2. Certificates in your login keychain:
#        - "Developer ID Application"  (signs the .app; needed for every target)
#        - "Developer ID Installer"    (signs the .pkg; needed for pkg/all)
#      Create both in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +.
#   3. A notary credential, stored once (the secret goes straight to the keychain):
#        xcrun notarytool store-credentials shotai-notary \
#          --apple-id "you@example.com" --team-id <TEAM_ID> --password "<app-specific-password>"
#
# Output → build/dist/shotAI-<version>.{dmg,pkg} : signed, notarized, stapled,
# Gatekeeper-verified.

set -euo pipefail

TARGET="${1:-dmg}"
case "$TARGET" in dmg|pkg|all) ;; *) echo "usage: $0 [dmg|pkg|all]" >&2; exit 2;; esac

# ---------------- config ----------------
SCHEME="shotAI"
APP_NAME="shotAI"
BUNDLE_ID="com.armadillon44.shotai"
NOTARY_PROFILE="${NOTARY_PROFILE:-shotai-notary}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$REPO/Signing/Distribution.entitlements"
DIST="$REPO/build/dist"
DD="$REPO/build/dist-dd"

cd "$REPO"
say() { printf '\033[1;35m▸ %s\033[0m\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

want_pkg() { [ "$TARGET" = "pkg" ] || [ "$TARGET" = "all" ]; }
want_dmg() { [ "$TARGET" = "dmg" ] || [ "$TARGET" = "all" ]; }

# ---------------- preflight ----------------
say "Preflight ($TARGET)"
APP_IDENTITY="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/ {print $2; exit}')"
[ -n "${APP_IDENTITY:-}" ] || die "No 'Developer ID Application' certificate in your keychain.
  Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + (needs an Apple Developer Program membership)."
echo "  app cert:   $APP_IDENTITY"
if want_pkg; then
  INSTALLER_IDENTITY="$(security find-identity -v | awk -F\" '/Developer ID Installer/ {print $2; exit}')"
  [ -n "${INSTALLER_IDENTITY:-}" ] || die "No 'Developer ID Installer' certificate (needed to sign a .pkg).
  Create it alongside the Application cert in Xcode ▸ Manage Certificates ▸ +."
  echo "  pkg cert:   $INSTALLER_IDENTITY"
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Create it once:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id <TEAM_ID> --password <app-specific-password>"
echo "  notary:     $NOTARY_PROFILE"

# ---------------- 1. clean Release build (unsigned; we sign explicitly) ----------------
say "Building Release (clean)"
rm -rf "$DD" "$DIST"; mkdir -p "$DIST"
xcodebuild -project shotAI.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO clean build >/dev/null
BUILT="$DD/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || die "build product missing: $BUILT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")"
APP="$DIST/$APP_NAME.app"; cp -R "$BUILT" "$APP"
echo "  $APP_NAME $VERSION"

# ---------------- 2. Developer ID sign the app (hardened runtime, inside-out) ----------------
say "Signing app (Developer ID + hardened runtime)"
while IFS= read -r f; do
  [ -n "$f" ] && codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$f"
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" -type f 2>/dev/null || true)
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "  code requirement (for the PPPC profile):"
codesign -d -r - "$APP" 2>/dev/null | sed 's/^/    /'

# ---------------- 3. notarize + staple the app ----------------
say "Notarizing app (uploads to Apple; ~1–5 min)"
APPZIP="$DIST/$APP_NAME-app.zip"
ditto -c -k --keepParent "$APP" "$APPZIP"
xcrun notarytool submit "$APPZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$APPZIP"

# ---------------- 4a. DMG ----------------
if want_dmg; then
  say "Packaging DMG"
  STAGE="$DIST/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  rm -rf "$STAGE"
  echo "  → $DMG"
fi

# ---------------- 4b. PKG (Intune / MDM) ----------------
if want_pkg; then
  say "Packaging PKG"
  PKG="$DIST/$APP_NAME-$VERSION.pkg"
  # Single-app product archive that installs to /Applications, signed with the
  # Developer ID *Installer* cert.
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" --timestamp "$PKG"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  echo "  → $PKG   (upload to Intune as a macOS app; pair with Intune/shotAI-PPPC.mobileconfig)"
fi

# ---------------- 5. verify Gatekeeper ----------------
say "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv "$APP" || true
want_dmg && spctl -a -t open --context context:primary-signature -vv "$DIST/$APP_NAME-$VERSION.dmg" || true
want_pkg && spctl -a -t install -vv "$DIST/$APP_NAME-$VERSION.pkg" || true
printf '\033[1;32m✅ Done → %s\033[0m\n' "$DIST"
