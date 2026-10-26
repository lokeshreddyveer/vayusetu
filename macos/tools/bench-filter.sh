#!/bin/bash
# Measures how fast the network filter decides a connection under load. See Tests/FilterBench.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/filter-tests
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/FilterModel.swift Filter/FilterProvider.swift Tests/FilterBench.swift -framework NetworkExtension -framework Network -framework Security -o build/filter-tests/bench 2>&1 | grep -E "error" || true
build/filter-tests/bench
