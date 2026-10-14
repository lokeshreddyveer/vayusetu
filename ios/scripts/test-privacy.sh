#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/privacy-tests
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk" -module-cache-path build/module-cache -parse-as-library -emit-library -static -emit-module -module-name VayuSetuCore ../Packages/VayuSetuCore/Sources/VayuSetuCore/*.swift -emit-module-path build/privacy-tests/VayuSetuCore.swiftmodule -o build/privacy-tests/libVayuSetuCore.a
xcrun swiftc -swift-version 5 -sdk "$sdk" -module-cache-path build/module-cache -parse-as-library -I build/privacy-tests Sources/Core.swift Sources/DNSOverTLS.swift Sources/Secrets.swift Sources/RoutePolicy.swift Sources/PublicIPProbe.swift Sources/NetworkDiagnostics.swift Sources/PrivacyFeatures.swift Sources/Backup.swift Tests/PrivacyStorageTests.swift build/privacy-tests/libVayuSetuCore.a -o build/privacy-tests/storage-tests -framework SafariServices -framework NetworkExtension -framework Network -framework Security -lsqlite3
build/privacy-tests/storage-tests
