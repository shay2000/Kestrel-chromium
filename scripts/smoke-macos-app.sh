#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: smoke-macos-app.sh /path/to/Kestrel.app output-directory}"
EVIDENCE_DIR="${2:?usage: smoke-macos-app.sh /path/to/Kestrel.app output-directory}"
STAGE="${3:-launch}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
mkdir -p "$EVIDENCE_DIR"

printf 'App: %s\nExecutable: %s\n' "$APP" "$EXECUTABLE" | tee "$EVIDENCE_DIR/launch.txt"

collect_failure_evidence() {
  local message="$1"
  echo "$message" | tee -a "$EVIDENCE_DIR/launch.txt"
  ps -axo pid=,comm=,args= | grep -Ei '[K]estrel|[C]hromium' \
    | tee "$EVIDENCE_DIR/processes.txt" || true
  log show --last 3m --style compact \
    --predicate "process == \"$EXECUTABLE\" OR process CONTAINS[c] \"Kestrel Helper\"" \
    > "$EVIDENCE_DIR/system-log.txt" 2>&1 || true
  DIAGNOSTIC_DIR=~/Library/Logs/DiagnosticReports
  mkdir -p "$EVIDENCE_DIR/diagnostic-reports"
  find "$DIAGNOSTIC_DIR" -maxdepth 1 -type f -name 'Kestrel*' -mmin -10 \
    -exec cp {} "$EVIDENCE_DIR/diagnostic-reports/" \; 2>/dev/null || true
  if [[ -s "$EVIDENCE_DIR/system-log.txt" ]]; then
    tail -n 100 "$EVIDENCE_DIR/system-log.txt" | tee -a "$EVIDENCE_DIR/launch.txt"
  fi
  for output in app-stdout.txt app-stderr.txt; do
    if [[ -s "$EVIDENCE_DIR/$output" ]]; then
      printf '\n--- %s ---\n' "$output" | tee -a "$EVIDENCE_DIR/launch.txt"
      cat "$EVIDENCE_DIR/$output" | tee -a "$EVIDENCE_DIR/launch.txt"
    fi
  done
  find "$EVIDENCE_DIR/diagnostic-reports" -maxdepth 1 -type f -print \
    | tee -a "$EVIDENCE_DIR/launch.txt"
  return 1
}

case "$STAGE" in
  launch)
    open -a "$APP" 2>&1 | tee -a "$EVIDENCE_DIR/launch.txt"
    PID=""
    for _ in $(seq 1 30); do
      PID="$(pgrep -x "$EXECUTABLE" | head -n 1 || true)"
      if [[ -n "$PID" ]]; then break; fi
      sleep 1
    done

    if [[ -z "$PID" ]]; then
      echo "LaunchServices did not leave a Kestrel process running; trying the app executable directly." \
        | tee -a "$EVIDENCE_DIR/launch.txt"
      nohup "$APP/Contents/MacOS/$EXECUTABLE" \
        > "$EVIDENCE_DIR/app-stdout.txt" 2> "$EVIDENCE_DIR/app-stderr.txt" < /dev/null &
      DIRECT_PID=$!
      printf 'Direct launch PID: %s\n' "$DIRECT_PID" | tee -a "$EVIDENCE_DIR/launch.txt"
      for _ in $(seq 1 30); do
        PID="$(pgrep -x "$EXECUTABLE" | head -n 1 || true)"
        if [[ -n "$PID" ]]; then break; fi
        sleep 1
      done
    fi

    if [[ -z "$PID" ]]; then
      collect_failure_evidence "Kestrel did not stay running after a blank launch."
    fi

    sleep 12
    if ! kill -0 "$PID" 2>/dev/null; then
      collect_failure_evidence "Kestrel process $PID exited during the blank-launch check."
    fi

    ps -p "$PID" -o pid=,comm= > "$EVIDENCE_DIR/process.txt"
    screencapture -x "$EVIDENCE_DIR/first-launch.png"
    printf 'Kestrel stayed alive for 12 seconds after a blank launch.\n' \
      | tee -a "$EVIDENCE_DIR/launch.txt"
    ;;
  navigate)
    PID="$(pgrep -x "$EXECUTABLE" | head -n 1 || true)"
    if [[ -z "$PID" ]]; then
      collect_failure_evidence "Kestrel was not running before the URL-open check."
    fi
    open -a "$APP" 'https://example.com/' 2>&1 | tee -a "$EVIDENCE_DIR/launch.txt"
    sleep 12
    PID="$(pgrep -x "$EXECUTABLE" | head -n 1 || true)"
    if [[ -z "$PID" ]] || ! kill -0 "$PID" 2>/dev/null; then
      collect_failure_evidence "Kestrel exited during the first URL-open check."
    fi

    ps -p "$PID" -o pid=,comm= > "$EVIDENCE_DIR/process-after-url.txt"
    screencapture -x "$EVIDENCE_DIR/after-url-open.png"
    log show --last 3m --style compact \
      --predicate "process == \"$EXECUTABLE\" OR process CONTAINS[c] \"Kestrel Helper\"" \
      > "$EVIDENCE_DIR/system-log.txt" 2>&1 || true
    printf 'Kestrel stayed alive for 12 seconds after opening https://example.com/.\n' \
      | tee -a "$EVIDENCE_DIR/launch.txt"
    ;;
  *)
    echo "usage: smoke-macos-app.sh /path/to/Kestrel.app output-directory [launch|navigate]" >&2
    exit 2
    ;;
esac
