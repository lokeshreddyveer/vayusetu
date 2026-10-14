#!/bin/bash
set -euo pipefail
cd "${SRCROOT}"
export PATH="$PWD/Tools/go/bin:$PATH"
export GOPATH="$PWD/Tools/gopath"
export GOCACHE="$PWD/build/go-cache"
export GOTOOLCHAIN=local
# Preserve WireGuard's continuous-clock runtime fix against the current Go source.
TASK_GOROOT="$PWD/build/patched-go"
if [ ! -f "$TASK_GOROOT/.prepared" ]; then
    mkdir -p "$TASK_GOROOT"
    /usr/bin/rsync -a Tools/go/ "$TASK_GOROOT/"
    /usr/bin/python3 - "$TASK_GOROOT" <<'PY'
import sys
from pathlib import Path
root=Path(sys.argv[1])
for name in ['sys_darwin.go','sys_darwin_amd64.s','sys_darwin_arm64.s']:
    p=root/'src/runtime'/name
    text=p.read_text()
    assert 'libc_mach_absolute_time' in text
    text=text.replace('libc_mach_absolute_time','libc_mach_continuous_time').replace(' mach_absolute_time ', ' mach_continuous_time ')
    p.write_text(text)
(root/'.prepared').touch()
PY
fi
export GOROOT="$TASK_GOROOT"
mkdir -p "$CONFIGURATION_BUILD_DIR"
case "$PLATFORM_NAME" in
iphoneos) export GOOS=ios;;
iphonesimulator) export GOOS=ios;;
*) exit 1;;
esac
SDKPATH="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
outputs=()
for arch in $ARCHS; do
    case "$arch" in arm64) export GOARCH=arm64;; x86_64) export GOARCH=amd64;; *) exit 1;; esac
    target="$arch-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}"
    if [ "$PLATFORM_NAME" = iphonesimulator ]; then target="$target-simulator"; fi
    export CGO_ENABLED=1
    export CC="$(xcrun --find clang)"
    export CGO_CFLAGS="-target $target -isysroot $SDKPATH"
    export CGO_LDFLAGS="$CGO_CFLAGS"
    output="$CONFIGURATION_TEMP_DIR/wg-$arch.a"
    mkdir -p "$CONFIGURATION_TEMP_DIR"
    go -C Vendor/wireguard-apple/Sources/WireGuardKitGo build -trimpath -ldflags=-w -buildmode=c-archive -o "$output"
    outputs+=("$output")
done
xcrun lipo -create "${outputs[@]}" -output "$CONFIGURATION_BUILD_DIR/libwg-go.a"
