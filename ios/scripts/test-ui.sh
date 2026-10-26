#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ -z "${1:-}" ]; then
    echo 'Usage: bash scripts/test-ui.sh <connected-unlocked-iPhone-UDID>' >&2
    exit 2
fi
mkdir -p build
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
xcodebuild -project VayuSetu.xcodeproj -scheme VayuSetuUI -configuration Debug -destination "id=$1" -derivedDataPath build/VayuSetu-ui-tests -allowProvisioningUpdates -resultBundlePath "build/UI-Regression-$run_id.xcresult" -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 test > "build/UI-Regression-$run_id.log" 2>&1
# A pass only counts once it is recorded from the real result bundle, with the device, the counts and the source it ran on (see scripts/ui-evidence.py).
# Skipped tests are listed in the record and are not counted as passed. Without this record the release verification reports the UI suite as not run.
device_name="$(xcrun xctrace list devices 2>/dev/null | grep -F "$1" | head -1 | sed 's/ ([0-9A-F-]*)$//')"
python3 scripts/ui-evidence.py record "build/UI-Regression-$run_id.xcresult" "${device_name:-$1}"
printf 'UI regression finished. Result: build/UI-Regression-%s.xcresult\n' "$run_id"
