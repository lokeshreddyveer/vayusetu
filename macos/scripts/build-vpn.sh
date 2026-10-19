#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
base="$PWD/../ios/Vendor/wireguard-apple/Sources"
export GOPATH="$PWD/../ios/Tools/gopath"
export GOCACHE="$PWD/build/go-cache"
export GOROOT="$PWD/../ios/build/patched-go"
export GOTOOLCHAIN=local
export GOOS=darwin CGO_ENABLED=1
export CC="$(xcrun --find clang)"
if [ ! -f "$GOROOT/.prepared" ]; then
    echo 'Build the iOS extension first to prepare the pinned patched Go runtime.' >&2
    exit 2
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
app='dist/VayuSetuVPN.app'
ext="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension"
mkdir -p build/module-cache "$app/Contents/MacOS" "$app/Contents/Resources" "$ext/Contents/MacOS" "$ext/Contents/Resources"
for arch in arm64 x86_64; do
    mkdir -p "build/vpn-$arch"
    if [ "$arch" = arm64 ]; then export GOARCH=arm64; else export GOARCH=amd64; fi
    export CGO_CFLAGS="-target $arch-apple-macos14.0 -isysroot $sdk"
    export CGO_LDFLAGS="$CGO_CFLAGS"
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -emit-library -static -emit-module -module-name VayuSetuCore ../Packages/VayuSetuCore/Sources/VayuSetuCore/*.swift -emit-module-path "build/$arch/VayuSetuCore.swiftmodule" -o "build/$arch/libVayuSetuCore.a"
    "$GOROOT/bin/go" -C "$base/WireGuardKitGo" build -trimpath -buildmode=c-archive -o "$PWD/build/vpn-$arch/libwg-go.a"
    for c in key x25519; do xcrun clang -target "$arch-apple-macos14.0" -isysroot "$sdk" -g -I "$base/WireGuardKitC" -c "$base/WireGuardKitC/$c.c" -o "build/vpn-$arch/$c.o"; done
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -I "build/$arch" -D VPN_ENABLED Sources/*.swift ../ios/Sources/Core.swift ../ios/Sources/DNSOverTLS.swift ../ios/Sources/Secrets.swift ../ios/Sources/RoutePolicy.swift ../ios/Sources/Store.swift ../ios/Sources/TunnelController.swift ../ios/Sources/NetworkDiagnostics.swift ../ios/Sources/Backup.swift ../ios/Sources/FeatureViews.swift ../ios/Sources/DesignSystem.swift ../ios/Sources/ProfileViews.swift ../ios/Sources/DNSViews.swift ../ios/Sources/CheckViews.swift ../ios/Sources/HomeSettingsViews.swift ../ios/Sources/ConnectionVerification.swift ../ios/Sources/VerificationViews.swift ../ios/Sources/FilteringDiagnostics.swift ../ios/Sources/FilteringViews.swift ../ios/Sources/PublicIPProbe.swift ../ios/Sources/IPDiscoveryViews.swift ../ios/Sources/PrivacyFeatures.swift ../ios/Sources/PrivacyFeatureViews.swift ../ios/Sources/ArchitectureViews.swift ../ios/Sources/FilteringArchitectureViews.swift "build/$arch/libVayuSetuCore.a" -o "build/vpn-$arch/VayuSetuVPN" -framework SwiftUI -framework MapKit -framework AppKit -framework Security -framework NetworkExtension -framework Network -framework SystemExtensions -framework ServiceManagement -framework SafariServices -framework WebKit -lsqlite3
    xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -module-name VayuSetuTunnel -application-extension -import-objc-header ../ios/Tunnel/Bridge.h -I "$base/WireGuardKitC" -I "$base/WireGuardKitGo" Tunnel/Main.swift ../ios/Tunnel/PacketTunnelProvider.swift ../ios/Tunnel/WireGuardConfigPolicy.swift ../ios/Tunnel/DNSOnlyRuntime.swift ../ios/Sources/Core.swift ../ios/Sources/DNSOverTLS.swift ../ios/Sources/Secrets.swift ../ios/Sources/RoutePolicy.swift "$base"/WireGuardKit/*.swift "$base/Shared/Model/TunnelConfiguration+WgQuickConfig.swift" "$base/Shared/Model/String+ArrayConversion.swift" "build/vpn-$arch/key.o" "build/vpn-$arch/x25519.o" "build/vpn-$arch/libwg-go.a" -o "build/vpn-$arch/VayuSetuTunnel" -framework NetworkExtension -framework Network -framework Security -lresolv
 done
xcrun lipo -create build/vpn-arm64/VayuSetuVPN build/vpn-x86_64/VayuSetuVPN -output "$app/Contents/MacOS/VayuSetuVPN"
xcrun lipo -create build/vpn-arm64/VayuSetuTunnel build/vpn-x86_64/VayuSetuTunnel -output "$ext/Contents/MacOS/VayuSetuTunnel"
python3 scripts/release/package-symbols.py
python3 scripts/vpn-bundle.py
cp dist/VayuSetu.app/Contents/Resources/AppIcon.icns "$app/Contents/Resources/"
cp ../Design/AppIcons/ArtisticBridge/VayuSetu-iOS-1024.png "$app/Contents/Resources/BrandArtwork.png"
cp ../ios/Configuration/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
cp ../ios/Configuration/PrivacyInfo.xcprivacy "$ext/Contents/Resources/"
cp ../ios/Configuration/ThirdPartyNotices.txt "$app/Contents/Resources/"
# A local build is deliberately not entitled to activate a VPN. Release signing adds validated profiles/entitlements.
codesign --force --sign - --options runtime "$ext"
bash scripts/build-safari.sh "$app"
cp -R Resources/Geo "$app/Contents/Resources/"
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
printf 'Built universal VPN host and WireGuard system extension. Provisioned release signing is required for activation.\n'

