#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage='build/DMG-VPN'
mkdir -p "$stage"
rm -rf "$stage/VayuSetuVPN.app"
ditto dist/VayuSetuVPN.app "$stage/VayuSetuVPN.app"
ln -sfn /Applications "$stage/Applications"
cp Resources/Install-VPN.txt "$stage/Read Me.txt"
version=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' dist/VayuSetuVPN.app/Contents/Info.plist)
dmg="dist/VayuSetuVPN-$version-macOS-unsigned.dmg"
hdiutil create -volname 'VayuSetu VPN Development' -srcfolder "$stage" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
