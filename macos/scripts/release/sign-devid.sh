#!/bin/bash
# Developer ID build for direct download: embeds the Developer ID profiles, signs inside-out with the hardened runtime and writes a signed DMG.
# Profiles come from build/devid-profiles/<bundle-id>.provisionprofile (created through the App Store Connect API). No upload is performed.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
identity="${VAYU_SIGN_IDENTITY:-19A381A318E0D484CF1494860C88985F711253B8}"
version=$(python3 -c 'import plistlib; print(plistlib.load(open("dist/VayuSetuVPN.app/Contents/Info.plist","rb"))["CFBundleShortVersionString"])')
build=$(python3 -c 'import plistlib; print(plistlib.load(open("dist/VayuSetuVPN.app/Contents/Info.plist","rb"))["CFBundleVersion"])')
root=build/devid; app="$root/VayuSetu.app"
rm -rf "$root"; mkdir -p "$root" dist/release
ditto dist/VayuSetuVPN.app "$app"
rm -rf "$app/Contents/_CodeSignature"
ext="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension"
profile() { cp "build/devid-profiles/$1.provisionprofile" "$2/Contents/embedded.provisionprofile"; }
sign() { codesign --force --timestamp --options runtime --entitlements "$2" --sign "$identity" "$1"; }
profile app.vayusetu.macos.tunnel "$ext"; sign "$ext" build/auto-sign/Tunnel.entitlements
for name in Ads Privacy Security Social Annoyances Custom; do
    lower=$(echo "$name" | tr 'A-Z' 'a-z')
    appex="$app/Contents/PlugIns/VayuSetuSafari$name.appex"
    profile "app.vayusetu.macos.safari$lower" "$appex"; sign "$appex" "build/auto-sign/Safari$name.entitlements"
done
cp build/devid-profiles/app.vayusetu.macos.provisionprofile "$app/Contents/embedded.provisionprofile"
sign "$app" build/auto-sign/Host.entitlements
codesign --verify --deep --strict --verbose=2 "$app"
spctl -a -t exec -vv "$app" || true
rm -rf "$root/DMG"; mkdir -p "$root/DMG"
ditto "$app" "$root/DMG/VayuSetu.app"; ln -sfn /Applications "$root/DMG/Applications"
dmg="dist/release/VayuSetu-$version-$build-macOS.dmg"
rm -f "$dmg"
hdiutil create -volname 'VayuSetu' -srcfolder "$root/DMG" -format UDZO -ov "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
hdiutil verify "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
echo "Signed DMG ready: $dmg. Not notarized and not uploaded."
