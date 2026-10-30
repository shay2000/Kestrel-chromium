#!/usr/bin/env bash
# Opt-in packaging of the official runtime already installed by the builder.
# No downloads, host credentials, runtime resources or login files are copied.
set -euo pipefail
APP="$1"
SOURCE="${KESTREL_CODEX_EXECUTABLE:-}"
HOST_APP="$APP/Contents/Helpers/KestrelCodexHost.app"
DESTINATION="$HOST_APP/Contents/MacOS/codex"
mkdir -p "$APP/Contents/Helpers"
if [[ -z "$SOURCE" ]]; then
  rm -rf "$HOST_APP"
  exit 0
fi
if [[ ! -f "$SOURCE" || ! -x "$SOURCE" ]]; then
  echo 'error: KESTREL_CODEX_EXECUTABLE must name an installed official Codex binary.' >&2
  exit 1
fi
# Deliberately pin the protocol/runtime tested by this integration. Supporting
# another architecture or version requires its own checksum and signed QA.
EXPECTED='0196e89fe5a7598f816ee54232c3d7c26d75e502ab5cfe2c9240e81d90f7255a'
ACTUAL="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo 'error: expected official Codex 0.156.1 for Apple silicon; checksum differs.' >&2
  exit 1
fi
mkdir -p "$HOST_APP/Contents/Helpers" "$HOST_APP/Contents/MacOS" "$APP/Contents/Resources/Licences"
cp -L "$SOURCE" "$DESTINATION"
chmod 755 "$DESTINATION"
cp "$(dirname "$0")/../resources/licences/Codex-LICENSE.txt" "$APP/Contents/Resources/Licences/"
xattr -c "$DESTINATION"
# This login agent is deliberately outside the browser sandbox, so official
# Codex can use its normal sign-in. macOS approval and mutual code-signing
# checks protect the XPC boundary; the browser receives no host file exception.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$IDENTITY" ]]; then IDENTITY=-; fi
codesign --force --sign "$IDENTITY" "$DESTINATION"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOST_APP/Contents/Library/LaunchAgents"
cat > "$HOST_APP/Contents/Library/LaunchAgents/com.shayprasad.Kestrel.CodexAgent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.shayprasad.Kestrel.CodexAgent</string>
<key>BundleProgram</key><string>Contents/MacOS/KestrelCodexHost</string>
<key>ProgramArguments</key><array><string>KestrelCodexHost</string><string>--agent</string></array>
<key>MachServices</key><dict><key>com.shayprasad.Kestrel.CodexAgent</key><true/></dict>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
codesign --verify --strict "$DESTINATION"


cat > "$HOST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KestrelCodexHost</string>
<key>CFBundleIdentifier</key><string>com.shayprasad.Kestrel.CodexHost</string>
<key>CFBundleName</key><string>Kestrel Codex Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HOST_BUILD" "$HOST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0.0' "$HOST_APP/Contents/Info.plist"
# Embed the helper identity in the executable as well as its bundle. Service
# Management must identify the same executable when launchd starts it directly.
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 "$ROOT/KestrelWebKit/CodexBridgeProtocol.swift" "$ROOT/scripts/CodexBridgeService.swift" "$ROOT/scripts/CodexHostApp.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HOST_APP/Contents/Info.plist" \
  -framework AppKit -framework Security -framework ServiceManagement -o "$HOST_APP/Contents/MacOS/KestrelCodexHost"
codesign --force --options runtime --sign "$IDENTITY" "$HOST_APP"
codesign --verify --deep --strict "$HOST_APP"
