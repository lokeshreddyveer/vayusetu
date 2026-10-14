#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/module-cache
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Tests/CoreTests.swift -o build/core-tests
build/core-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Tests/RouteTests.swift -o build/route-tests -framework Security -framework NetworkExtension
build/route-tests
base=Vendor/wireguard-apple/Sources
for file in key x25519; do xcrun clang -isysroot "$SDK" -I "$base/WireGuardKitC" -c "$base/WireGuardKitC/$file.c" -o "build/$file.o"; done
models=()
for file in "$base"/WireGuardKit/*.swift; do
    case "$file" in */WireGuardAdapter.swift|*/PacketTunnelSettingsGenerator.swift|*/DNSResolver.swift|*/Array+ConcurrentMap.swift) continue;; esac
    models+=("$file")
done
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache -import-objc-header Tunnel/Bridge.h -I "$base/WireGuardKitC" -I "$base/WireGuardKitGo" Sources/Core.swift Sources/DNSOverTLS.swift Tunnel/WireGuardConfigPolicy.swift "${models[@]}" "$base/Shared/Model/TunnelConfiguration+WgQuickConfig.swift" "$base/Shared/Model/String+ArrayConversion.swift" Tests/WireGuardPolicyTests.swift build/key.o build/x25519.o -o build/wireguard-policy-tests
build/wireguard-policy-tests

xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/Runtime.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/Protection.swift Tests/RuntimeTests.swift -o build/runtime-tests
build/runtime-tests

xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Sources/Backup.swift Sources/PublicIPProbe.swift Sources/NetworkDiagnostics.swift Tests/FeatureTests.swift -o build/feature-tests -framework CryptoKit -framework Security -framework Network -framework NetworkExtension
build/feature-tests

xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/PublicIPProbe.swift Sources/NetworkDiagnostics.swift Sources/ConnectionVerification.swift Sources/FilteringDiagnostics.swift Tests/VerificationTests.swift -o build/verification-tests -framework Network
build/verification-tests

xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/PublicIPProbe.swift Tests/IPProbeTests.swift -o build/ip-probe-tests -framework Network
build/ip-probe-tests

xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Tests/ManualProtocolTests.swift -o build/manual-protocol-tests
build/manual-protocol-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Tests/QRAndIKETests.swift -o build/qr-ike-tests -framework Security -framework NetworkExtension
build/qr-ike-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Sources/Backup.swift Sources/PublicIPProbe.swift Sources/NetworkDiagnostics.swift Tests/ProfileManagementTests.swift -o build/profile-management-tests -framework CryptoKit -framework Security -framework Network -framework NetworkExtension
build/profile-management-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Tunnel/DNSOnlyRuntime.swift Tests/DNSOnlyTests.swift -o build/dns-only-tests -framework Security -framework Network -framework NetworkExtension
build/dns-only-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/Coordinator.swift Tests/CoordinatorTests.swift -o build/coordinator-tests
build/coordinator-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/DNSDashboard.swift Tests/DNSDashboardTests.swift -o build/dns-dashboard-tests
build/dns-dashboard-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/Coordinator.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/DNSDashboard.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/ProfilesDashboard.swift Tests/ProfilesDashboardTests.swift -o build/profiles-dashboard-tests
build/profiles-dashboard-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/Filtering.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/ABPContentParser.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/PublicSuffixData.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/FilterCatalog.swift Tests/FilterCatalogTests.swift -o build/filter-catalog-tests
build/filter-catalog-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/ActivityModel.swift Tests/ActivityTests.swift -o build/activity-tests
build/activity-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/Filtering.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/ABPContentParser.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/PublicSuffixData.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/FilterCatalog.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/SafariPlanner.swift ../Packages/VayuSetuCore/Sources/VayuSetuCore/SafariRankBoost.swift Tests/SafariPlannerTests.swift -o build/safari-planner-tests
build/safari-planner-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/ABPContentParser.swift Tests/ContentParserTests.swift -o build/content-parser-tests
build/content-parser-tests
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path build/module-cache ../Packages/VayuSetuCore/Sources/VayuSetuCore/FilterHealth.swift Tests/FilterHealthTests.swift -o build/filter-health-tests
build/filter-health-tests
