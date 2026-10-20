#!/bin/bash
# Builds the network-filter system extension (universal) and puts it inside an app bundle. Usage: build-filter.sh <app bundle>
# The filter is separate from the VPN tunnel so a problem in one cannot stop the other. It is only added to the Developer ID (DMG) build.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
app="${1:?app bundle}"
ext="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.filter.systemextension"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/module-cache build/filter-arm64 build/filter-x86_64 "$ext/Contents/MacOS" "$ext/Contents/Resources"
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -module-name VayuSetuFilter -application-extension \
        Filter/Main.swift Filter/FilterProvider.swift Sources/FilterModel.swift -o "build/filter-$arch/VayuSetuFilter" -framework NetworkExtension -framework Network -framework Security
done
xcrun lipo -create build/filter-arm64/VayuSetuFilter build/filter-x86_64/VayuSetuFilter -output "$ext/Contents/MacOS/VayuSetuFilter"
python3 - "$ext" <<'PY'
import plistlib, sys
from pathlib import Path
ext = Path(sys.argv[1])
team = 'X4MH29QNRS'
info = {
    'CFBundleName': 'VayuSetu Network Filter', 'CFBundleDisplayName': 'VayuSetu Network Filter',
    'CFBundleIdentifier': 'app.vayusetu.macos.filter', 'CFBundleExecutable': 'VayuSetuFilter', 'CFBundlePackageType': 'SYSX',
    'CFBundleVersion': '37', 'CFBundleShortVersionString': '1.0', 'LSMinimumSystemVersion': '14.0',
    'NSSystemExtensionUsageDescription': 'VayuSetu uses this network extension to show which apps connect where, and to block connections you choose.',
    'NetworkExtension': {'NEMachServiceName': team + '.app.vayusetu.filter.xpc',
                         'NEProviderClasses': {'com.apple.networkextension.filter-data': 'VayuSetuFilter.VayuFilterProvider'}},
}
(ext / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
echo "Built the network filter extension into $ext"
