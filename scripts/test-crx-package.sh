#!/usr/bin/env bash
# Run the production verifier's XCTest suite without compiling CEF or the
# retained WebKit-only integration tests. SwiftPM supplies the native runner.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: CRX signature tests require macOS CryptoKit and Security." >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kestrel-crx-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Sources/ExtensionVerifier" "$TEST_DIR/Tests/ExtensionVerifierTests"
cp "$ROOT/KestrelChromium/CRXPackage.swift" "$TEST_DIR/Sources/ExtensionVerifier/"
printf '%s\n' '@testable import ExtensionVerifier' > "$TEST_DIR/Tests/ExtensionVerifierTests/CRXPackageTests.swift"
cat "$ROOT/Tests/KestrelWebKitTests/CRXPackageTests.swift" >> "$TEST_DIR/Tests/ExtensionVerifierTests/CRXPackageTests.swift"
cat > "$TEST_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KestrelCRXChecks", platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ExtensionVerifier", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ExtensionVerifierTests", dependencies: ["ExtensionVerifier"],
                    swiftSettings: [.define("KESTREL_CRX_TESTS"), .swiftLanguageMode(.v5)])
    ]
)
SWIFT
swift test --package-path "$TEST_DIR"
