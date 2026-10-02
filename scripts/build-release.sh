#!/bin/bash
# Builds a universal, ad-hoc signed Release Tether.app and packages Tether-<version>.dmg.
# Usage: scripts/build-release.sh [--version X.Y.Z] [--build N] [--smoke] [--out DIR]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="" BUILD="" SMOKE=0 OUT="dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --smoke) SMOKE=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION" ] || VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}/\1/p' project.yml | head -1)
[ -n "$BUILD" ] || BUILD=$(git rev-list --count HEAD)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version '$VERSION'" >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "bad build '$BUILD'" >&2; exit 2; }

[ -f Vendor/build/lib/libmtp.9.dylib ] || Vendor/build-libs.sh
DD="$PWD/DerivedData/release"
LOG="$DD/build.log"; mkdir -p "$DD" "$OUT"
xcodegen generate >/dev/null
if ! xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -derivedDataPath "$DD" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" ONLY_ACTIVE_ARCH=NO \
      clean build >"$LOG" 2>&1; then
  tail -40 "$LOG" >&2; echo "release build failed (log: $LOG)" >&2; exit 1
fi
grep -E "warning: .*\.swift" "$LOG" && { echo "Swift warnings in Release build" >&2; exit 1; }

APP="$OUT/Tether.app"
rm -rf "$APP" && ditto "$DD/Build/Products/Release/Tether.app" "$APP"

# Verify: every Mach-O is universal.
fail=0
while IFS= read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "missing slice in $f: $archs" >&2; fail=1; }
  fi
done < <(find "$APP" -type f \( -perm -u+x -o -name "*.dylib" \))
[ $fail -eq 0 ] || exit 1

# Verify: versions, credits, signature.
plist="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$VERSION" ] || { echo "version mismatch" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" = "$BUILD" ] || { echo "build mismatch" >&2; exit 1; }
grep -q "GNU Lesser General Public License" "$APP/Contents/Resources/Credits.rtf" || { echo "Credits.rtf missing LGPL text" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "codesign verify failed" >&2; exit 1; }

# DMG: app + Applications link + acknowledgements.
STAGE="$DD/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tether.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/Credits.rtf" "$STAGE/Acknowledgements.rtf"
DMG="$OUT/Tether-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Tether $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "built $DMG ($(stat -f %z "$DMG") bytes), version $VERSION ($BUILD)"

if [ $SMOKE -eq 1 ]; then
  # Mount, copy out like a user would, launch in real mode, confirm the helper loads libmtp.
  MNT=$(mktemp -d); hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
  TRY=$(mktemp -d); ditto "$MNT/Tether.app" "$TRY/Tether.app"; hdiutil detach "$MNT" >/dev/null
  before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -E "^(Tether|MTPHelper)" || true)
  CACHE=$(mktemp -d)
  "$TRY/Tether.app/Contents/MacOS/Tether" -CacheDirectory "$CACHE" >/dev/null 2>&1 & pid=$!
  ok=0; for _ in $(seq 1 20); do sleep 0.5; pgrep -f "Tether.app/Contents/XPCServices/MTPHelper.xpc" >/dev/null && { ok=1; break; }; done
  sleep 2
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  after=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -E "^(Tether|MTPHelper)" || true)
  [ $ok -eq 1 ] || { echo "smoke: MTPHelper never started" >&2; exit 1; }
  [ "$after" -le "$before" ] || { echo "smoke: new crash report in ~/Library/Logs/DiagnosticReports" >&2; exit 1; }
  echo "smoke: app launched, MTPHelper running, no crash reports"
fi
