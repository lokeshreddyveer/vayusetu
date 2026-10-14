#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage='build/DMG'
mkdir -p "$stage"
# Only replace the generated app inside this dedicated packaging directory.
rm -rf "$stage/VayuSetu.app"
ditto dist/VayuSetu.app "$stage/VayuSetu.app"
ln -sfn /Applications "$stage/Applications"
cp Resources/Install.txt "$stage/Read Me.txt"
# The bundle is the single source of truth for the version in artifact names.
version=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' dist/VayuSetu.app/Contents/Info.plist)
dmg="dist/VayuSetu-$version-macOS.dmg"
hdiutil create -volname VayuSetu -srcfolder "$stage" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
printf 'DMG: %s/%s\n' "$PWD" "$dmg"
