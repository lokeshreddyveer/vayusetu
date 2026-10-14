#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/module-cache dist
bash scripts/test.sh
for scheme in VayuSetu VayuSetuVPN; do
    for platform in simulator device; do
        if [ "$platform" = simulator ]; then sdk=iphonesimulator; destination='generic/platform=iOS Simulator'; else sdk=iphoneos; destination='generic/platform=iOS'; fi
        output="build/$scheme-$platform"
        log="build/$scheme-$platform.log"
        xcodebuild -project VayuSetu.xcodeproj -scheme "$scheme" -configuration Debug -sdk "$sdk" -destination "$destination" -derivedDataPath "$output" CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || { tail -60 "$log"; exit 1; }
        product="$output/Build/Products/Debug-$sdk/$scheme.app"
        target="dist/$scheme-$platform.app"
        rm -rf "$target"
        cp -R "$product" "$target"
        printf 'Built %s for %s (unsigned).\n' "$scheme" "$platform"
    done
done
python3 scripts/verify.py
