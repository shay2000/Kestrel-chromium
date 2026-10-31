#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: smoke-macos-app.sh /path/to/Kestrel.app output-directory}"
EVIDENCE_DIR="${2:?usage: smoke-macos-app.sh /path/to/Kestrel.app output-directory}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
mkdir -p "$EVIDENCE_DIR"

printf 'App: %s\nExecutable: %s\n' "$APP" "$EXECUTABLE" | tee "$EVIDENCE_DIR/launch.txt"
open -a "$APP" 'https://example.com/' 2>&1 | tee -a "$EVIDENCE_DIR/launch.txt"

PID=""
for _ in $(seq 1 30); do
  PID="$(pgrep -x "$EXECUTABLE" | head -n 1 || true)"
  if [[ -n "$PID" ]]; then break; fi
  sleep 1
done

if [[ -z "$PID" ]]; then
  echo "Kestrel exited before its first-launch smoke check completed." | tee -a "$EVIDENCE_DIR/launch.txt"
  ps -axo pid=,comm=,args= | grep -Ei '[K]estrel|[C]hromium' \
    | tee "$EVIDENCE_DIR/processes.txt" || true
  log show --last 3m --style compact \
    --predicate "process == \"$EXECUTABLE\" OR process CONTAINS[c] \"Kestrel Helper\"" \
    > "$EVIDENCE_DIR/system-log.txt" 2>&1 || true
  cat "$EVIDENCE_DIR/system-log.txt" | tee -a "$EVIDENCE_DIR/launch.txt"
  exit 1
fi

sleep 12
if ! kill -0 "$PID" 2>/dev/null; then
  echo "Kestrel process $PID exited during its first-launch smoke check." | tee -a "$EVIDENCE_DIR/launch.txt"
  ps -axo pid=,comm=,args= | grep -Ei '[K]estrel|[C]hromium' \
    | tee "$EVIDENCE_DIR/processes.txt" || true
  log show --last 3m --style compact \
    --predicate "process == \"$EXECUTABLE\" OR process CONTAINS[c] \"Kestrel Helper\"" \
    > "$EVIDENCE_DIR/system-log.txt" 2>&1 || true
  cat "$EVIDENCE_DIR/system-log.txt" | tee -a "$EVIDENCE_DIR/launch.txt"
  exit 1
fi

ps -p "$PID" -o pid=,comm= > "$EVIDENCE_DIR/process.txt"
screencapture -x "$EVIDENCE_DIR/first-launch.png"
log show --last 3m --style compact \
  --predicate "process == \"$EXECUTABLE\" OR process CONTAINS[c] \"Kestrel Helper\"" \
  > "$EVIDENCE_DIR/system-log.txt" 2>&1 || true
printf 'Kestrel stayed alive for 12 seconds after opening https://example.com/.\n' \
  | tee -a "$EVIDENCE_DIR/launch.txt"
