#!/bin/bash
# Type-checks the Mac app (arm64 only, no optimisation) so shared-code changes can be verified in a minute instead of a full build.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
files=$(sed -n '/^    xcrun swiftc.*Sources\/\*\.swift/p' scripts/build.sh | head -1 | grep -o '\.\./ios/Sources/[A-Za-z]*\.swift' | tr '\n' ' ')
xcrun swiftc -typecheck -swift-version 5 -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path build/module-cache -parse-as-library -I build/arm64 Sources/*.swift $files 2>&1 | grep -E "error:" | sort -u | head -${1:-40}
