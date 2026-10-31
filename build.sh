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
  --bundle-id com.shayprasad.Kestrel \
  --sign -

# CefSwift assembles and signs the CEF framework and helper apps. Add Kestrel's
# app resources, Sparkle's dynamic framework and browser permission
# descriptions, then re-sign the app container so its resource seal includes
# them while preserving nested code.
mkdir -p "$APP/Contents/Resources"
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -path '*/Sparkle.framework' -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: the resolved Sparkle.framework was not found under .build/artifacts." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/licenses/Sparkle-LICENSE.txt" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
RESOURCE_BUNDLE="$(find "$ROOT/.build" -type d -name 'KestrelChromium_KestrelWebKit.bundle' -path "*/$CONFIG/*" -print -quit)"
if [[ -z "$RESOURCE_BUNDLE" || ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "error: the compiled Kestrel resource bundle was not found under .build for $CONFIG." >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/KestrelChromium_KestrelWebKit.bundle"
cp "$ROOT/KestrelWebKit/Kestrel.icns" "$APP/Contents/Resources/Kestrel.icns"
INFO="$APP/Contents/Info.plist"
set_plist_string() {
  local key="$1" value="$2"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$INFO" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$INFO"
}
set_plist_bool() {
  local key="$1" value="$2"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$INFO" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$INFO"
}
set_plist_string CFBundleDisplayName "Kestrel Chromium"
set_plist_string CFBundleIconFile Kestrel.icns
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$VERSION"
set_plist_string LSApplicationCategoryType public.app-category.utilities
set_plist_string NSCameraUsageDescription "Websites you visit may ask to use your camera."
set_plist_string NSMicrophoneUsageDescription "Websites you visit may ask to use your microphone."
set_plist_string NSLocationUsageDescription "Websites you visit may ask to use your location."
set_plist_string NSLocationWhenInUseUsageDescription "Websites you visit may ask to use your location."
set_plist_string NSDownloadsFolderUsageDescription "Files you download are saved to your Downloads folder."
set_plist_string SUFeedURL "https://github.com/shay2000/Kestrel-chromium/releases/latest/download/appcast.xml"
set_plist_string SUPublicEDKey "1Fe/NeDkmo8kFRAvGxgma0GKqbad8w3is5pGuHSwkdc="
set_plist_bool SUEnableAutomaticChecks true
set_plist_bool SUEnableInstallerLauncherService true

if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$INFO" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$INFO"
fi
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0' "$INFO" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0 dict' "$INFO"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer' "$INFO"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLName string HTTP and HTTPS web pages' "$INFO"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$INFO"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string http' "$INFO"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string https' "$INFO"
fi

if ! /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' "$INFO" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$INFO"
fi
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Set :NSAppTransportSecurity:NSAllowsArbitraryLoads true' "$INFO"
cp "$ROOT/licenses/CEF-LICENSE.txt" "$APP/Contents/Resources/CEF-LICENSE.txt"
cp "$ROOT/licenses/CefSwift-LICENSE.txt" "$APP/Contents/Resources/CefSwift-LICENSE.txt"
bash "$ROOT/scripts/package-codex-runtime.sh" "$APP"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "built: $APP"
