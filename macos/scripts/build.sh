#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/module-cache dist
app='dist/VayuSetu.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    mkdir -p "build/$arch"
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -emit-library -static -emit-module -module-name VayuSetuCore ../Packages/VayuSetuCore/Sources/VayuSetuCore/*.swift -emit-module-path "build/$arch/VayuSetuCore.swiftmodule" -o "build/$arch/libVayuSetuCore.a"
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -I "build/$arch" Sources/*.swift ../ios/Sources/Core.swift ../ios/Sources/DNSOverTLS.swift ../ios/Sources/Secrets.swift ../ios/Sources/RoutePolicy.swift ../ios/Sources/Store.swift ../ios/Sources/TunnelController.swift ../ios/Sources/NetworkDiagnostics.swift ../ios/Sources/Backup.swift ../ios/Sources/FeatureViews.swift ../ios/Sources/DesignSystem.swift ../ios/Sources/ProfileViews.swift ../ios/Sources/DNSViews.swift ../ios/Sources/CheckViews.swift ../ios/Sources/HomeSettingsViews.swift ../ios/Sources/ConnectionVerification.swift ../ios/Sources/VerificationViews.swift ../ios/Sources/FilteringDiagnostics.swift ../ios/Sources/FilteringViews.swift ../ios/Sources/PublicIPProbe.swift ../ios/Sources/IPDiscoveryViews.swift ../ios/Sources/PrivacyFeatures.swift ../ios/Sources/PrivacyFeatureViews.swift ../ios/Sources/ArchitectureViews.swift ../ios/Sources/FilteringArchitectureViews.swift "build/$arch/libVayuSetuCore.a" -o "build/$arch/VayuSetu" -framework SwiftUI -framework AppKit -framework Security -framework NetworkExtension -framework Network -framework SystemExtensions -framework ServiceManagement -framework SafariServices -framework WebKit -lsqlite3
 done
xcrun lipo -create build/arm64/VayuSetu build/x86_64/VayuSetu -output "$app/Contents/MacOS/VayuSetu"
python3 scripts/bundle.py
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cp ../Design/AppIcons/ArtisticBridge/VayuSetu-iOS-1024.png "$app/Contents/Resources/BrandArtwork.png"
cp ../ios/Configuration/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
cp ../ios/Configuration/ThirdPartyNotices.txt "$app/Contents/Resources/"
bash scripts/build-safari.sh "$app"
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
printf 'Built universal VayuSetu.app (local ad-hoc signing).\n'
