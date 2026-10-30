#!/usr/bin/env bash
# Build Kestrel's Chromium Embedded Framework (CEF) macOS app bundle.
#
#   ./build.sh            release .app
#   ./build.sh debug      debug .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="${KESTREL_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/Kestrel.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: CEF app bundles must be built on macOS." >&2
  exit 1
fi

case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

cd "$ROOT"
swift package \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef bundle \
  --product Kestrel \
  --configuration "$CONFIG" \
  --output "$BUILD_DIR" \
  --bundle-id com.shayprasad.KestrelChromium \
  --sign -

# CefSwift assembles and signs the CEF framework and helper apps. Add Kestrel's
# icon to the completed bundle, then re-sign the app container so its resource
# seal includes the icon while leaving the nested CEF signatures intact.
cp "$ROOT/KestrelWebKit/Kestrel.icns" "$APP/Contents/Resources/Kestrel.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Kestrel.icns' "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Kestrel.icns' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp "$ROOT/licenses/CEF-LICENSE.txt" "$APP/Contents/Resources/CEF-LICENSE.txt"
cp "$ROOT/licenses/CefSwift-LICENSE.txt" "$APP/Contents/Resources/CefSwift-LICENSE.txt"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "built: $APP"
