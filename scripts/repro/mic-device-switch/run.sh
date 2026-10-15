#!/bin/bash
# Repro harness for DEBUGGING-LOG 2026-10-10 ("hotkey does nothing and Space stops working").
# Compiles the REAL Sources/Lisper/Audio/AudioRecorder.swift (its `import LisperKit` stripped,
# two LisperKit types stubbed in stubs.swift — keep them in sync) and drives it through input
# device switches. It TEMPORARILY creates a "Lisper Harness Mic" aggregate device and makes it
# the default input; on exit (even a failed or interrupted run) it removes the aggregate and
# restores your original default input and the built-in mic's sample rate. Prints GREEN/RED.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$H/../../.." && pwd)"
B="${TMPDIR:-/tmp}/lisper-mic-switch-harness"; mkdir -p "$B"; rm -f "$B/harness"
# AUDIO_RECORDER_SRC=<file> runs it against another version (e.g. to confirm it goes RED on old code).
grep -v '^import LisperKit' "${AUDIO_RECORDER_SRC:-$ROOT/Sources/Lisper/Audio/AudioRecorder.swift}" > "$B/AudioRecorder.swift"
clang -c "$H/catch.m" -o "$B/catch.o" -fobjc-arc -I"$H"
swiftc -swift-version 5 -O -import-objc-header "$H/catch.h" "$H/main.swift" "$H/stubs.swift" \
  "$H/devrate.swift" "$B/AudioRecorder.swift" "$B/catch.o" -o "$B/harness" 2> "$B/compile.log" \
  || { grep -v warning "$B/compile.log"; echo "COMPILE FAILED"; exit 2; }
read -r ORIG_DEFAULT ORIG_RATE < <("$B/harness" state)
trap '"$B/harness" cleanup "$ORIG_DEFAULT" "$ORIG_RATE"' EXIT
"$B/harness"
