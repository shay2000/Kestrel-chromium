#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="${1:-$ROOT/.build/checkouts/CefSwift}"
PIN=b18cceef8afaf6686147e19a9239f31c2dd81541
test "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$PIN" || {
  echo "error: CefSwift lifecycle patch requires the reviewed pinned revision $PIN" >&2
  exit 1
}
PATCH="$ROOT/patches/cefswift-browser-lifecycle.patch"
if git -C "$CHECKOUT" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "CefSwift lifecycle patch is already applied."
else
  git -C "$CHECKOUT" apply --check "$PATCH"
  git -C "$CHECKOUT" apply "$PATCH"
  echo "Applied CefSwift browser lifecycle patch at $PIN"
fi
