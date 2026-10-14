#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export GOPATH="$PWD/Tools/gopath"
export GOCACHE="$PWD/build/security-go-cache"
export GOROOT="$PWD/build/patched-go"
export GOTOOLCHAIN=local
export GOBIN="$PWD/build/security-tools"
export PATH="$GOROOT/bin:$PATH"
mkdir -p build/security-reports "$GOBIN"
# These are module integrity and known-vulnerability checks, not a cryptographic audit.
"$GOROOT/bin/go" -C Vendor/wireguard-apple/Sources/WireGuardKitGo mod verify > build/security-reports/module-integrity.txt
"$GOROOT/bin/go" -C Vendor/wireguard-apple/Sources/WireGuardKitGo list -m -json all > build/security-reports/dependency-inventory.json
"$GOROOT/bin/go" install golang.org/x/vuln/cmd/govulncheck@v1.8.0
cd Vendor/wireguard-apple/Sources/WireGuardKitGo
# Retain broad module findings, then gate on analysis of the actual iOS build.
set +e
"$GOBIN/govulncheck" -scan=module -json > ../../../../build/security-reports/go-module-vulnerabilities.json
module_status=$?
set -e
if [ "$module_status" -ne 0 ] && [ "$module_status" -ne 3 ]; then exit "$module_status"; fi
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
export CC="$(xcrun --find clang)"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
export CGO_CFLAGS="-target arm64-apple-ios18.0 -isysroot $sdk"
export CGO_LDFLAGS="$CGO_CFLAGS"
"$GOROOT/bin/go" list -deps ./... > ../../../../build/security-reports/ios-package-inventory.txt
"$GOBIN/govulncheck" -json ./... > ../../../../build/security-reports/go-vulnerabilities.json
