#!/usr/bin/env bash
# Run the package verifier's XCTest suite without building the CEF runtime or
# compiling the retained WebKit-only integration tests against Chromium.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kestrel-crx-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import XCTest
XCTMain([testCase(CRXPackageTests.allTests)])
SWIFT
swiftc -swift-version 5 -D KESTREL_CRX_TESTS \
  "$ROOT/KestrelChromium/CRXPackage.swift" \
  "$ROOT/Tests/KestrelWebKitTests/CRXPackageTests.swift" \
  "$TEST_DIR/main.swift" -o "$TEST_DIR/crx-tests"
"$TEST_DIR/crx-tests"
