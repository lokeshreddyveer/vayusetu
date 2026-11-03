#!/bin/bash
# Builds a measurement copy of the Mac app: optimised like the release, plus the debug-only screen tour (PerfTour.swift). The copy is a different
# app (own bundle id, no system extensions inside) so it can never touch the installed extensions, profiles or Keychain. Output: build/perf-app/VayuSetuPerf.app
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"; arch=arm64
mkdir -p build/module-cache build/perf-app "build/perf-$arch"
xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -emit-library -static -emit-module -module-name VayuSetuCore ../Packages/VayuSetuCore/Sources/VayuSetuCore/*.swift -emit-module-path "build/perf-$arch/VayuSetuCore.swiftmodule" -o "build/perf-$arch/libVayuSetuCore.a"
cmd=$(sed -n '/^    xcrun swiftc.*Sources\/\*\.swift/p' scripts/build.sh | head -1)
cmd=${cmd//-g -O/-O -DDEBUG}
cmd=${cmd//build\/\$arch/build\/perf-\$arch}
eval "$cmd"
app=build/perf-app/VayuSetuPerf.app
rm -rf "$app"; ditto /Applications/VayuSetu.app "$app"
rm -rf "$app/Contents/Library" "$app/Contents/PlugIns" "$app/Contents/embedded.provisionprofile" "$app/Contents/_CodeSignature"
cp "build/perf-$arch/VayuSetu" "$app/Contents/MacOS/VayuSetu"
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --output-format human-readable-text >/dev/null
/usr/libexec/PlistBuddy -c "Add :NSAccentColorName string AccentColor" "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :NSAccentColorName AccentColor" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.vayusetu.perf" -c "Set :CFBundleName VayuSetuPerf" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
echo "Built $app"
