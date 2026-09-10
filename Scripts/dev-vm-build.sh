#!/usr/bin/env bash
# Debug build that actually RUNS on another Mac — specifically the Parallels
# arm64 guest used for hand-testing, which reaches this repo over a shared folder.
#
# The ordinary `xcodebuild ... build` output at build/shotAI.app is fine on this
# machine and USELESS anywhere else. Three independent reasons, all of which
# surface as Finder's "damaged or incomplete" rather than the usual Gatekeeper
# prompt, because validation fails outright instead of merely distrusting:
#
#   1. It is signed with the Apple Development identity, whose designated
#      requirement pins that leaf certificate. A development identity is only
#      valid on the machine holding it unless the bundle carries a provisioning
#      profile, and this one deliberately carries none.
#   2. Xcode's debug-dylib layout: the executable is a ~58 KB stub that loads
#      Contents/MacOS/shotAI.debug.dylib, plus a __preview.dylib.
#   3. Debug builds only the active arch.
#
# So: ad-hoc sign (no certificate to validate), collapse to one real binary, and
# build both arches. Verified portable by moving the build directory away and
# launching the copy — dyld resolved everything.
#
# The HOST build keeps Apple Development signing on purpose: TCC keys grants to
# the code-signing designated requirement, and a stable one is what stops Screen
# Recording / Accessibility / Input Monitoring being orphaned on every rebuild.
# Do not "unify" these two recipes; they exist for opposite reasons.
#
# Usage: bash Scripts/dev-vm-build.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="$REPO/build/vm-dd"          # stable, so rebuilds are incremental
OUT="$REPO/build/vm"
cd "$REPO"

echo "▸ Debug build — ad-hoc, single binary, universal"
xcodebuild -project shotAI.xcodeproj -scheme shotAI -configuration Debug \
  -derivedDataPath "$DD" \
  ENABLE_DEBUG_DYLIB=NO \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build >/dev/null

BUILT="$DD/Build/Products/Debug/shotAI.app"
[ -d "$BUILT" ] || { echo "✗ build product missing" >&2; exit 1; }

mkdir -p "$OUT"; rm -rf "$OUT/shotAI.app"; cp -R "$BUILT" "$OUT/shotAI.app"
APP="$OUT/shotAI.app"

# Fail loudly rather than hand over something that dies on the guest.
echo "▸ Portability checks"
# NB: capture into variables, never `… | grep -q` under `set -o pipefail`.
# grep -q exits at the first match, the producer takes SIGPIPE, and pipefail
# then fails the whole pipeline — so the check reports a problem that is not
# there. That cost a debugging round on the first run of this script.
EXES=$(ls "$APP/Contents/MacOS/" | wc -l | tr -d ' ')
[ "$EXES" = "1" ] || { echo "✗ $EXES executables — the debug dylib is back" >&2; exit 1; }

ARCHS=$(lipo -archs "$APP/Contents/MacOS/shotAI")
case "$ARCHS" in *arm64*) ;; *) echo "✗ no arm64 slice ($ARCHS)" >&2; exit 1 ;; esac

SIG=$(codesign -dvv "$APP" 2>&1 || true)
case "$SIG" in *"Signature=adhoc"*) ;; *)
  echo "✗ not ad-hoc signed — it will not open on the guest" >&2; exit 1 ;; esac

codesign --verify --deep --strict "$APP" 2>/dev/null \
  || { echo "✗ signature does not verify" >&2; exit 1; }

# Dependency lines are indented; a UNIVERSAL binary prints one unindented
# "…(architecture x):" header PER ARCH, so `tail -n +2` is not enough — it
# strips one header and counts the other as a dependency.
DEPS=$(otool -L "$APP/Contents/MacOS/shotAI" | grep "^	" | grep -vcE "/usr/lib|/System" || true)
[ "$DEPS" = "0" ] || {
  echo "✗ $DEPS non-system dylib dependencies:" >&2
  otool -L "$APP/Contents/MacOS/shotAI" | grep "^	" | grep -vE "/usr/lib|/System" >&2
  exit 1
}

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
echo "  arch:      $(lipo -archs "$APP/Contents/MacOS/shotAI")"
echo "  signature: ad-hoc, verifies"
echo "  version:   $VERSION ($(git rev-parse --short HEAD))"
echo "  → $APP"
echo
echo "On the guest: copy it out of the shared folder into /Applications first."
echo "Running an app in place from a Parallels share is where odd TCC and"
echo "quarantine behaviour comes from, and a copy costs nothing."
