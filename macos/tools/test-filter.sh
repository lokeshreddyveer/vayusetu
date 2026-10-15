#!/bin/bash
# Compiles and runs the filter rule-engine tests on this Mac. No network and no extension needed.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/filter-tests
xcrun swiftc -swift-version 5 -parse-as-library Sources/FilterModel.swift Tests/FilterRuleTests.swift -o build/filter-tests/run
build/filter-tests/run
