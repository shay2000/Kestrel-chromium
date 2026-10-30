#!/usr/bin/env bash
# Build a local, double-clickable Kestrel app bundle from SwiftPM.
#
#   ./build.sh              debug app bundle
#   ./build.sh release      release app bundle
#
# KESTREL_SWIFTPM_EXTRA_ARGS passes extra flags to `swift build`. Environments
# whose sandbox forbids SwiftPM's own subprocess sandbox need
# `KESTREL_SWIFTPM_EXTRA_ARGS=--disable-sandbox`; leave it unset elsewhere.
#
# The script is intentionally macOS-oriented. Linux can validate the SwiftPM
# fallback target, but only macOS has the WebKit UI and app-bundle runtime.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="Kestrel"
PACKAGE_PRODUCT="Kestrel"
BUNDLE_ID="com.shayprasad.Kestrel"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
BUILD_DIR="${KESTREL_BUILD_DIR:-build}"
APP="${BUILD_DIR}/${APP_NAME}.app"
SWIFTPM_BUILD_DIR="${KESTREL_SWIFTPM_BUILD_DIR:-.build}"
BINARY=""
RESOURCE_BUNDLE=""
SPARKLE_FRAMEWORK=""

swift build -c "$CONFIG" --scratch-path "$SWIFTPM_BUILD_DIR" ${KESTREL_SWIFTPM_EXTRA_ARGS:-}

# SwiftPM's output layout varies by toolchain; ask it for the resolved product
# directory instead of assuming `.build/debug`.
PRODUCTS_DIR="$(swift build -c "$CONFIG" --scratch-path "$SWIFTPM_BUILD_DIR" ${KESTREL_SWIFTPM_EXTRA_ARGS:-} --show-bin-path)"
BINARY="${PRODUCTS_DIR}/${PACKAGE_PRODUCT}"
RESOURCE_BUNDLE="${PRODUCTS_DIR}/KestrelWebKit_KestrelWebKit.bundle"
SPARKLE_FRAMEWORK="${PRODUCTS_DIR}/Sparkle.framework"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "KestrelWebKit/Kestrel.icns" "$APP/Contents/Resources/Kestrel.icns"

# SwiftPM copies the shared asset catalogue into a resource bundle.
# Keep it in the standard signed-app resource directory; KestrelAssets
# resolves this location before SwiftPM's checkout-dependent generated accessor.
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
  echo "error: expected SwiftPM asset bundle at $RESOURCE_BUNDLE" >&2
  exit 1
fi

# Command-line SwiftPM leaves xcassets uncompiled. SwiftUI's named image lookup
# needs Assets.car for provider and attachment marks, including their SVGs.
xcrun actool KestrelWebKit/Assets.xcassets \
  --compile "$APP/Contents/Resources/KestrelWebKit_KestrelWebKit.bundle" \
  --platform macosx --minimum-deployment-target 14.0 --target-device mac \
  --output-format human-readable-text --warnings --notices
test -s "$APP/Contents/Resources/KestrelWebKit_KestrelWebKit.bundle/Assets.car"
swift - "$APP/Contents/Resources/KestrelWebKit_KestrelWebKit.bundle" <<'SWIFT'
import AppKit
guard let assets = Bundle(path: CommandLine.arguments[1]) else {
  fatalError("Packaged asset bundle is unreadable")
}
for name in ["ProviderOpenAI", "AttachmentText", "KestrelIconBasic", "KestrelIconDark"] {
  guard let image = assets.image(forResource: NSImage.Name(name)),
        let pixels = image.tiffRepresentation, !pixels.isEmpty else {
    fatalError("Packaged image is unreadable: \(name)")
  }
  print("Verified packaged image: \(name)")
}
SWIFT

# Sparkle is a dynamic framework. Keep its signed helpers and XPC services
# intact inside the app bundle so automatic and manual checks both work.
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
  # SwiftPM's executable is linked for its product directory, not an app's
  # Contents/Frameworks layout. Signing alone cannot detect a missing rpath:
  # the packaged app otherwise aborts in dyld before opening its first window.
  if ! otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -F '@executable_path/../Frameworks' > /dev/null; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/$APP_NAME"
  fi
fi

# Info.plist is also used by the Xcode project, so resolve its build-setting
# placeholders when SwiftPM is used directly.
sed \
  -e "s|\$(EXECUTABLE_NAME)|${APP_NAME}|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" \
  -e "s|\$(PRODUCT_NAME)|Kestrel|g" \
  -e "s|\$(MARKETING_VERSION)|${VERSION}|g" \
  -e "s|\$(CURRENT_PROJECT_VERSION)|${BUILD}|g" \
  "KestrelWebKit/Info.plist" > "$APP/Contents/Info.plist"

# Xcode compiles Assets.xcassets into Assets.car, but this SwiftPM builder
# copies the generated Kestrel.icns directly. Remove the Xcode-only icon-name
# key from this bundle so Launch Services resolves the copied ICNS resource.
if command -v plutil >/dev/null 2>&1; then
  plutil -remove CFBundleIconName "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Bundle Codex only when the builder explicitly supplies the pinned runtime.
# The opt-in native companion owns the host agent; the browser stays sandboxed.
bash scripts/package-codex-runtime.sh "$APP"

# Ad-hoc signing is enough for a local build. Keep the local sandbox and network
# entitlements consistent with Xcode. The network-server entitlement is used
# only by the opt-in MCP listener, which binds to loopback.
if command -v codesign >/dev/null 2>&1; then
  # Workspace and file-provider metadata can be attached to the new bundle
  # directory and make codesign reject it as containing resource-fork data.
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP"
  fi
  ENTITLEMENTS="${BUILD_DIR}/Kestrel.entitlements.plist"
  sed -e 's|\$(PRODUCT_BUNDLE_IDENTIFIER)|com.shayprasad.Kestrel|g' \
    "KestrelWebKit/Entitlements/KestrelWebKit.entitlements" > "$ENTITLEMENTS"
  codesign --force \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$APP" >/dev/null
  rm -f "$ENTITLEMENTS"
  codesign --verify --deep --strict "$APP"

  # Check that the entitlements actually landed on the bundle.
  #
  # If signing is interrupted — a killed process, a full disk, a tool that
  # exits 0 anyway — the bundle keeps the linker's bare signature on its
  # executable. That signature carries no entitlements, so the app runs
  # *unsandboxed*, and an unsandboxed Kestrel reads ~/Library/Preferences
  # instead of its sandbox container. Everything saved in the container —
  # bookmarks, recent searches, chat history — then looks like it has been
  # deleted, and it keeps writing to the wrong file until the next good build.
  # A silent data-loss failure deserves a loud error instead.
  if ! codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - \
      | grep -q "com.apple.security.app-sandbox"; then
    echo "error: $APP was signed without its sandbox entitlements." >&2
    echo "error: delete it and run this script again before launching Kestrel." >&2
    exit 1
  fi
fi

echo "built: $APP ($VERSION, build $BUILD)"
