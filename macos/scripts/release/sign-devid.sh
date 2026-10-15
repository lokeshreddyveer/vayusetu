#!/bin/bash
# Developer ID build for direct download: embeds the Developer ID profiles, signs inside-out with the hardened runtime and writes a signed DMG.
# Profiles come from build/devid-profiles/<bundle-id>.provisionprofile (created through the App Store Connect API). No upload is performed.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
identity="${VAYU_SIGN_IDENTITY:-19A381A318E0D484CF1494860C88985F711253B8}"
version=$(python3 -c 'import plistlib; print(plistlib.load(open("dist/VayuSetuVPN.app/Contents/Info.plist","rb"))["CFBundleShortVersionString"])')
build=$(python3 -c 'import plistlib; print(plistlib.load(open("dist/VayuSetuVPN.app/Contents/Info.plist","rb"))["CFBundleVersion"])')
export VAYU_DEVELOPMENT_TEAM="${VAYU_DEVELOPMENT_TEAM:-X4MH29QNRS}"
# Regenerates build/auto-sign/*.plist (Info.plist values: Keychain groups, app group, Mach service name) and *.entitlements from the fresh build.
python3 scripts/release/configure-auto-sign.py
root=build/devid; app="$root/VayuSetu.app"
rm -rf "$root"; mkdir -p "$root" dist/release
ditto dist/VayuSetuVPN.app "$app"
rm -rf "$app/Contents/_CodeSignature"
# The release must carry the same Info.plist values as the Xcode-signed build: without them the app and the tunnel cannot share the Keychain
# profile and the extension has no valid Mach service name.
ext0="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension"
cp build/auto-sign/Host.plist "$app/Contents/Info.plist"
cp build/auto-sign/Tunnel.plist "$ext0/Contents/Info.plist"
for name in Ads Privacy Security Social Annoyances Custom; do cp "build/auto-sign/Safari$name.plist" "$app/Contents/PlugIns/VayuSetuSafari$name.appex/Contents/Info.plist"; done
ext="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension"
profile() { cp "build/devid-profiles/$1.provisionprofile" "$2/Contents/embedded.provisionprofile"; }
sign() { codesign --force --timestamp --options runtime --entitlements "$2" --sign "$identity" "$1"; }
# A system extension's Mach service name must start with an app group the extension belongs to; the tunnel's name is
# "<team>.app.vayusetu.macos.tunnel", so it needs the group "<team>.app.vayusetu.macos". Without it macOS refuses to install the extension.
python3 - "$root" <<'TENT'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1]); team = 'X4MH29QNRS'
ent = plistlib.loads(Path('build/auto-sign/Tunnel.entitlements').read_bytes())
groups = ent.setdefault('com.apple.security.application-groups', [])
if team + '.app.vayusetu.macos' not in groups: groups.append(team + '.app.vayusetu.macos')
Path(root/'Tunnel.entitlements').write_bytes(plistlib.dumps(ent))
TENT
profile app.vayusetu.macos.tunnel "$ext"; sign "$ext" "$root/Tunnel.entitlements"
# The network filter: its own system extension, added only to this Developer ID build.
bash scripts/build-filter.sh "$app"
filter="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.filter.systemextension"
python3 - "$root" <<'ENT'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1]); team = 'X4MH29QNRS'
group = team + '.app.vayusetu.filter'
Path(root/'Filter.entitlements').write_bytes(plistlib.dumps({
    'com.apple.application-identifier': team + '.app.vayusetu.macos.filter', 'com.apple.developer.team-identifier': team,
    'com.apple.developer.networking.networkextension': ['content-filter-provider-systemextension'],
    'com.apple.security.application-groups': [group]}))   # not sandboxed: it has to inspect other apps' code signatures
host = plistlib.loads(Path('build/auto-sign/Host.entitlements').read_bytes())
ne = host.setdefault('com.apple.developer.networking.networkextension', [])
if 'content-filter-provider-systemextension' not in ne: ne.append('content-filter-provider-systemextension')
groups = host.setdefault('com.apple.security.application-groups', [])
if group not in groups: groups.append(group)
Path(root/'Host.entitlements').write_bytes(plistlib.dumps(host))
ENT
profile app.vayusetu.macos.filter "$filter"; sign "$filter" "$root/Filter.entitlements"
for name in Ads Privacy Security Social Annoyances Custom; do
    lower=$(echo "$name" | tr 'A-Z' 'a-z')
    appex="$app/Contents/PlugIns/VayuSetuSafari$name.appex"
    profile "app.vayusetu.macos.safari$lower" "$appex"; sign "$appex" "build/auto-sign/Safari$name.entitlements"
done
cp build/devid-profiles/app.vayusetu.macos.provisionprofile "$app/Contents/embedded.provisionprofile"
sign "$app" "$root/Host.entitlements"
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
python3 - "$app" <<'CHECK'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
host = plistlib.loads((app/'Contents/Info.plist').read_bytes())
ext = plistlib.loads((app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension/Contents/Info.plist').read_bytes())
for key in ('VayuAppGroup', 'VayuKeychainGroup', 'VayuAppKeychainGroup'): assert host.get(key), 'host Info.plist is missing ' + key
assert ext.get('VayuKeychainGroup'), 'extension Info.plist is missing VayuKeychainGroup'
assert 'SIGNING_TEAM_REQUIRED' not in ext['NetworkExtension']['NEMachServiceName'], 'Mach service name is still the placeholder'
print('Info.plist values verified:', ext['NetworkExtension']['NEMachServiceName'])
import subprocess
out = subprocess.run(['codesign', '-d', '--entitlements', '-', str(app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension')], capture_output=True, text=True).stdout + ''
assert 'X4MH29QNRS.app.vayusetu.macos' in out and 'application-groups' in out, 'the tunnel is missing the app group its Mach service name needs'
print('Tunnel app group verified')
CHECK
echo "Signed DMG ready: $dmg. Not notarized and not uploaded."
