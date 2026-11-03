#!/bin/bash
# Reproducible release verification. One command, no hand-set environment: it finds full Xcode itself (the command-line tools alone cannot run the
# package tests or xcodebuild, which is why those fail in a default shell), runs every check, verifies the signed artifact, and prints one
# PASS/FAIL line per step with an exit status of 0 only when nothing failed or was skipped without being asked.
#
#   macos/tools/verify-release.sh <path-to-dmg> [--skip-ios] [--skip-build] [--no-artifact]
#
#   --skip-ios    do not run the iPhone compile check (reported as SKIPPED, and the run then exits 2, never 0)
#   --skip-build  verify the artifact only (reported the same way)
#   --no-artifact verify the source only, before a disk image exists (reported as SKIPPED, so the run exits 2, never 0)
set -uo pipefail
cd "$(dirname "$0")/../.."          # repository root
DMG="${1:-}"; shift || true
SKIP_IOS=0; SKIP_BUILD=0; NO_ARTIFACT=0
[ "$DMG" = "--no-artifact" ] && { NO_ARTIFACT=1; DMG=""; }
for a in "$@"; do case "$a" in --skip-ios) SKIP_IOS=1;; --skip-build) SKIP_BUILD=1;; --no-artifact) NO_ARTIFACT=1;; esac; done

XCODE="/Applications/Xcode.app/Contents/Developer"
[ -d "$XCODE" ] || { echo "FAIL  full Xcode is not installed at /Applications/Xcode.app; the package tests and the iOS compile cannot run"; exit 1; }
export DEVELOPER_DIR="$XCODE"
export GOPATH="$PWD/ios/Tools/gopath" GOCACHE="$PWD/macos/build/go-cache" GOROOT="$PWD/ios/build/patched-go" GOTOOLCHAIN=local CGO_ENABLED=1

pass=0; fail=0; skipped=0; REPORT="${TMPDIR:-/tmp}/vayusetu-verify.txt"; : > "$REPORT"
say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
ok()   { pass=$((pass+1)); say "PASS    $1"; }
bad()  { fail=$((fail+1)); say "FAIL    $1"; }
skip() { skipped=$((skipped+1)); say "SKIPPED $1"; }
step() { # step <name> <command...>: PASS when the command exits 0; its output tail is kept for a failure
  local name="$1"; shift; local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ]; then ok "$name"; else bad "$name (exit $rc)"; printf '%s\n' "$out" | tail -8 | sed 's/^/        /' | tee -a "$REPORT"; fi
}

say "VayuSetu release verification   $(date '+%Y-%m-%d %H:%M:%S')"
say "Developer directory: $DEVELOPER_DIR   (the system's own setting is $(env -u DEVELOPER_DIR xcode-select -p 2>/dev/null); this script does not depend on it)"
say "Source: $(git rev-parse --short HEAD 2>/dev/null) $(git diff --quiet 2>/dev/null && echo clean || echo 'with uncommitted changes')"
say ""

# ---- version configuration (fast, no compile) ----
step "Mac version configuration is consistent (scripts/version.json)" python3 macos/tools/check-versions.py
step "iPhone version configuration is consistent (Configuration/Version.json)" python3 ios/scripts/check-versions.py
step "no unreachable dialogs in any screen (a confirmation nothing can open)" python3 ios/scripts/check-dead-state.py
step "no force unwraps or force-try that input can reach" python3 ios/scripts/check-unwraps.py
step "no animation that runs forever or cannot pause" python3 ios/scripts/check-animations.py
step "no test or diagnostic launch arguments outside debug builds" python3 ios/scripts/check-debug-hooks.py
step "no closures stored in the SwiftUI environment" python3 ios/scripts/check-env-closures.py
step "build status document matches the versions and recorded runs" python3 ios/scripts/build-status.py --check
say ""

# ---- the checks that compile ----
if [ $SKIP_BUILD -eq 1 ]; then skip "core package tests, Go tests, DNS runtime checks, Mac type check"; else
  step "core package tests (all, zero failures)" bash -c 'cd Packages/VayuSetuCore && out=$(swift test 2>&1); echo "$out" | tail -3; echo "$out" | grep -q "Test Suite .All tests. passed" && ! echo "$out" | grep -q "error:"'
  step "Go DNS filter tests" bash -c 'cd ios/Vendor/wireguard-apple/Sources/WireGuardKitGo && "$GOROOT/bin/go" test -count=1 .'
  step "Go formatting (the files this project added)" bash -c 'cd ios/Vendor/wireguard-apple/Sources/WireGuardKitGo && [ -z "$("$GOROOT/bin/gofmt" -l dnsrebinding.go dnsrebinding_test.go dnsstats.go dnsstats_test.go dnsdomains.go)" ]'
  step "DNS runtime checks (Swift)" bash -c 'cd ios && SDK=$(xcrun --sdk macosx --show-sdk-path) && mkdir -p build/module-cache && xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Tunnel/DNSOnlyRuntime.swift Tests/DNSOnlyTests.swift -o build/dns-only-tests -framework Security -framework Network -framework NetworkExtension 2>/dev/null && ./build/dns-only-tests | grep -q "checks passed"'
  step "network filter provider tests (ask mode, fail-open and fail-closed)" bash macos/tools/test-filter.sh
  step "privacy storage tests (retention, defaults, validation)" bash -c 'cd ios && bash scripts/test-privacy.sh | grep -q "^Passed"'
  step "Mac type check (core module rebuilt first, so it cannot be stale)" bash -c 'cd macos && rm -f build/arm64/VayuSetuCore.swiftmodule build/arm64/libVayuSetuCore.a && bash tools/typecheck.sh'
fi
if [ $SKIP_IOS -eq 1 ] || [ $SKIP_BUILD -eq 1 ]; then skip "iPhone compile check"; else
  step "iPhone UI test suite compiles (build-for-testing; this does not run it)" bash -c 'cd ios && out=$(xcodebuild build-for-testing -project VayuSetu.xcodeproj -scheme VayuSetuUI -destination "generic/platform=iOS" -derivedDataPath "${TMPDIR:-/tmp}/vs-verify-ui" CODE_SIGNING_ALLOWED=NO 2>&1); rm -rf "${TMPDIR:-/tmp}/vs-verify-ui"; echo "$out" | grep -E "TEST BUILD (SUCCEEDED|FAILED)"; echo "$out" | grep -q "TEST BUILD SUCCEEDED"'
  step "iPhone compile check (xcodebuild, no signing)" bash -c 'cd ios && out=$(xcodebuild -project VayuSetu.xcodeproj -scheme VayuSetu -destination "generic/platform=iOS" -derivedDataPath "${TMPDIR:-/tmp}/vs-verify-dd" CODE_SIGNING_ALLOWED=NO build 2>&1); rm -rf "${TMPDIR:-/tmp}/vs-verify-dd"; echo "$out" | grep -E "BUILD (SUCCEEDED|FAILED)"; echo "$out" | grep -q "BUILD SUCCEEDED"'
fi

# ---- the UI suite on a device: only a recorded real run counts ----
ui_out="$(python3 ios/scripts/ui-evidence.py check 2>&1)"; ui_rc=$?
case $ui_rc in
    0) ok "UI tests: $ui_out";;
    2) skip "UI tests have not been run on a device for this source: ${ui_out#NOT RUN  }";;
    *) bad "UI tests: $ui_out";;
esac

# ---- the source: a release is a clean, identified commit ----
src_changes="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ $NO_ARTIFACT -eq 1 ]; then
    [ "$src_changes" = "0" ] && ok "source is a clean commit $(git rev-parse --short HEAD)" || say "NOTE    the working tree has $src_changes uncommitted change(s); fine while developing, but a release must be built from a clean commit"
elif [ "$src_changes" = "0" ]; then ok "source is a clean commit $(git rev-parse --short HEAD)"
else bad "the working tree has $src_changes uncommitted change(s), so no artifact can be tied to one commit"; fi

# ---- the signed artifact ----
say ""
if [ $NO_ARTIFACT -eq 1 ]; then skip "signed artifact checks (no disk image was given)"
elif [ -z "$DMG" ] || [ ! -f "$DMG" ]; then bad "signed artifact: no DMG given or found (pass the path as the first argument)"; else
  say "Artifact: $DMG"
  step "stapled notarization ticket is valid" xcrun stapler validate "$DMG"
  step "Gatekeeper accepts the disk image (Notarized Developer ID)" bash -c 'spctl -a -t open --context context:primary-signature -vv "$0" 2>&1 | grep -q "accepted"' "$DMG"
  want="$(cut -d' ' -f1 "$DMG.sha256" 2>/dev/null)"; have="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$want" = "$have" ] && ok "SHA-256 matches the recorded file (${have:0:16}…)" || bad "SHA-256 does not match the recorded file"
  MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"; APP="$MOUNT/VayuSetu.app"
  if [ -d "$APP" ]; then
    step "app signature is valid (deep, strict)" codesign --verify --deep --strict "$APP"
    step "Gatekeeper accepts the app" bash -c 'spctl -a -vv "$0" 2>&1 | grep -q "accepted"' "$APP"
    id="$(plutil -p "$APP/Contents/Info.plist" | grep CFBundleIdentifier | cut -d'"' -f4)"; build="$(plutil -p "$APP/Contents/Info.plist" | grep CFBundleVersion | cut -d'"' -f4)"
    [ "$id" = "app.vayusetu.macos" ] && ok "bundle identifier $id, build $build" || bad "unexpected bundle identifier '$id'"
    case "$DMG" in *"-$build-"*) ok "the disk image name matches build $build";; *) bad "the disk image name does not match build $build";; esac
    for e in tunnel filter; do
      v="$(plutil -p "$APP/Contents/Library/SystemExtensions/app.vayusetu.macos.$e.systemextension/Contents/Info.plist" | grep CFBundleVersion | cut -d'"' -f4)"
      [ -n "$v" ] && ok "$e extension is version $v" || bad "$e extension version not found"
      step "$e extension signature is valid" codesign --verify --strict "$APP/Contents/Library/SystemExtensions/app.vayusetu.macos.$e.systemextension"
    done
    # macOS replaces an activated extension only when the new one has a higher version, and asks the person to approve it. Say what is active now.
    now="$(systemextensionsctl list 2>/dev/null | grep 'app.vayusetu.macos.tunnel' | grep activated | sed -n 's/.*(\([0-9.]*\/[0-9]*\)).*/\1/p' | head -1)"
    mine="$(plutil -p "$APP/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension/Contents/Info.plist" | grep CFBundleVersion | cut -d'"' -f4)"
    if [ -z "$now" ]; then say "NOTE    no tunnel extension is activated on this Mac yet"
    elif [ "${now##*/}" -lt "$mine" ] 2>/dev/null; then say "NOTE    the activated tunnel extension is version ${now##*/}; this build carries $mine, so macOS will ask to update it the first time protection is switched on"
    else say "NOTE    the activated tunnel extension (${now##*/}) is not older than this build's ($mine)"; fi
    [ "$(strings -a "$APP/Contents/MacOS/VayuSetuVPN" | grep -c 'debug-hide-home-panel')" = "0" ] && ok "no diagnostic switches in the release binary" || bad "a diagnostic switch is present in the release binary"
    hdiutil detach "$MOUNT" -quiet 2>/dev/null
    # The record written by release.sh ties this disk image to the commit that is checked out now.
    if [ -f "$DMG.source.json" ]; then
      rec="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['commit'], d['tree'], 'dirty' if d['dirty'] else 'clean', d['sha256'])" "$DMG.source.json" 2>/dev/null)"
      set -- $rec
      [ "${3:-}" = "clean" ] && ok "the artifact was built from a clean tree" || bad "the artifact was built from a tree with uncommitted changes (or the record is unreadable)"
      head_now="$(git rev-parse HEAD)"
      [ "${1:-}" = "$head_now" ] && ok "the artifact was built from the commit that is checked out (${1:0:10})" || bad "the artifact was built from commit ${1:0:10}, but ${head_now:0:10} is checked out"
      [ "${4:-}" = "$have" ] && ok "the source record's hash matches the disk image" || bad "the source record's hash does not match the disk image"
    else bad "no source record beside the disk image ($DMG.source.json): it cannot be tied to a commit"; fi
  else bad "could not mount the disk image"; fi
fi

say ""
say "Result: $pass passed, $fail failed, $skipped skipped.   Full report: $REPORT"
[ $fail -gt 0 ] && exit 1
[ $skipped -gt 0 ] && { say "Not a full verification: $skipped step(s) were skipped."; exit 2; }
exit 0
