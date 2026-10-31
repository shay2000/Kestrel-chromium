#!/usr/bin/env bash
# Apply the reviewed lifecycle fix to exactly the pinned Swift wrapper.
# CEF's binary, sandbox and helper packaging remain supplied by CefSwift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="${1:-$ROOT/.build/checkouts/CefSwift}"
EXPECTED_REVISION=b18cceef8afaf6686147e19a9239f31c2dd81541
PATCH="$ROOT/patches/cefswift-defer-termination.patch"
ACTUAL_REVISION="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ "$ACTUAL_REVISION" != "$EXPECTED_REVISION" ]]; then
  echo "error: review the CefSwift lifecycle patch before changing its pinned revision." >&2
  exit 1
fi
if git -C "$CHECKOUT" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "CefSwift lifecycle patch already applied at $EXPECTED_REVISION"
  exit 0
fi
git -C "$CHECKOUT" apply --check "$PATCH"
git -C "$CHECKOUT" apply "$PATCH"
echo "Applied CefSwift deferred-termination patch at $EXPECTED_REVISION"
