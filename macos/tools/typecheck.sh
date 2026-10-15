#!/bin/bash
# Type-checks the Mac app (arm64 only, no optimisation) so shared-code changes can be verified in a minute instead of a full build.
# Exit status is the compiler's: 0 when the type-check passes, non-zero when it fails. Full output goes to build/typecheck.log.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
files=$(sed -n '/^    xcrun swiftc.*Sources\/\*\.swift/p' scripts/build.sh | head -1 | grep -o '\.\./ios/Sources/[A-Za-z]*\.swift' | tr '\n' ' ')
mkdir -p build build/arm64 build/module-cache
# The core package is compiled once into build/arm64; rebuild it if a cleanup removed it.
if [ ! -f build/arm64/VayuSetuCore.swiftmodule ]; then
    xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path build/module-cache -parse-as-library -emit-library -static -emit-module -module-name VayuSetuCore ../Packages/VayuSetuCore/Sources/VayuSetuCore/*.swift -emit-module-path build/arm64/VayuSetuCore.swiftmodule -o build/arm64/libVayuSetuCore.a > build/typecheck-core.log 2>&1 || { echo "Could not build the core package: see build/typecheck-core.log"; exit 1; }
fi
xcrun swiftc -typecheck -swift-version 5 -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path build/module-cache -parse-as-library -I build/arm64 Sources/*.swift $files > build/typecheck.log 2>&1
status=$?
if [ $status -eq 0 ]; then echo "Type-check passed."; else echo "Type-check FAILED (exit $status). Full output: build/typecheck.log"; grep -E "error:" build/typecheck.log | sort -u | head -"${1:-40}"; fi
exit $status
