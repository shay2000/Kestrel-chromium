#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_REPO="shay2000/Kestrel-Browser"
SPARKLE_KEY_ACCOUNT="kestrel-browser"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v${VERSION}"
WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/kestrel-public-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be a three-part numeric release, got '$VERSION'." >&2
  exit 1
fi

if ! command -v gh >/dev/null || ! command -v xcodebuild >/dev/null; then
  echo "error: install GitHub CLI and Xcode before publishing a release." >&2
  exit 1
fi

if [[ "$(git -C "$ROOT" branch --show-current)" != "main" ]]; then
  echo "error: publish public releases only from the private repository's main branch." >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: commit or discard local changes before publishing a public release." >&2
  exit 1
fi
git -C "$ROOT" fetch --quiet origin main
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/main)" ]]; then
  echo "error: update local main to match origin/main before publishing." >&2
  exit 1
fi

IS_PRIVATE="$(gh repo view "$PUBLIC_REPO" --json isPrivate --jq .isPrivate)"
if [[ "$IS_PRIVATE" != "false" ]]; then
  echo "error: $PUBLIC_REPO must be public before publishing app updates." >&2
  exit 1
fi

EXPECTED_PUBLIC_FILES=$'README.md\nscreenshots/assistant-sidebar.png\nscreenshots/assistant.png\nscreenshots/new-tab.png\nscreenshots/shortcuts.png\nscreenshots/split-view.png'
PUBLIC_FILES="$(gh api "repos/$PUBLIC_REPO/git/trees/main?recursive=1" --jq '[.tree[] | select(.type == "blob") | .path] | sort | join("\n")')"
if [[ "$PUBLIC_FILES" != "$EXPECTED_PUBLIC_FILES" ]]; then
  echo "error: the public release repository must contain only README.md and the five approved screenshots; refusing to publish." >&2
  printf 'Expected public files:\n%s\nFound public files:\n%s\n' "$EXPECTED_PUBLIC_FILES" "$PUBLIC_FILES" >&2
  exit 1
fi

if gh api "repos/${PUBLIC_REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
  echo "error: the Git tag $TAG already exists on $PUBLIC_REPO; increment VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi

DERIVED="$WORK/Derived"
SOURCE_PACKAGES="$WORK/SourcePackages"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -resolvePackageDependencies \
  -project "$ROOT/KestrelWebKit.xcodeproj" \
  -scheme Kestrel \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"

DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -project "$ROOT/KestrelWebKit.xcodeproj" \
  -scheme Kestrel \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  MARKETING_VERSION="$VERSION" \
  build

APP="$DERIVED/Build/Products/Release/Kestrel.app"
codesign --verify --deep --strict "$APP"

STAGE="$WORK/Release"
mkdir -p "$STAGE"
ZIP="$STAGE/Kestrel-Browser.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

cat > "$STAGE/Kestrel-Browser.md" <<EOF
Kestrel Browser ${VERSION} introduces a native macOS browser with configurable keyboard shortcuts, independent split panes, and an integrated assistant.

- Runs on macOS 14 or later on Apple silicon and Intel Macs.
- Built-in update checks; choose Kestrel → Check for Updates… to check now.
- Assistant web search is enabled by default and can be controlled in Settings.
- Browser pages use Apple WebKit. This build does not claim full Chromium extension compatibility.

This release uses an ad-hoc signature because no Developer ID certificate was available to sign it. macOS may show a first-open warning; this build is not notarized.
EOF

GENERATOR="$SOURCE_PACKAGES/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$GENERATOR" ]]; then
  echo "error: Sparkle's generate_appcast tool was not found at $GENERATOR." >&2
  exit 1
fi

DOWNLOAD_PREFIX="https://github.com/${PUBLIC_REPO}/releases/download/${TAG}/"
"$GENERATOR" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/${PUBLIC_REPO}/releases/latest" \
  --embed-release-notes \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

gh release create "$TAG" \
  --repo "$PUBLIC_REPO" \
  --target main \
  --title "Kestrel Browser ${VERSION}" \
  --notes-file "$STAGE/Kestrel-Browser.md" \
  "$ZIP" "$STAGE/appcast.xml"

printf 'Published %s to https://github.com/%s/releases/tag/%s\n' "$VERSION" "$PUBLIC_REPO" "$TAG"
