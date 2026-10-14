#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${VAYU_DEVELOPMENT_TEAM:?Set your provisioned team ID}"
: "${VAYU_SIGN_IDENTITY:?Set your Developer ID Application signing identity}"
: "${VAYU_APP_PROFILE:?Set host provisioning profile path}"
: "${VAYU_TUNNEL_PROFILE:?Set extension provisioning profile path}"
python3 - <<'IDENTITY'
import os,re,subprocess
identity=os.environ['VAYU_SIGN_IDENTITY'];team=os.environ['VAYU_DEVELOPMENT_TEAM']
output=subprocess.check_output(['security','find-identity','-v','-p','codesigning']).decode()
valid=re.findall(r'\b([0-9A-F]{40}) "(Developer ID Application:[^"]+)"',output)
matches=[(fingerprint,name) for fingerprint,name in valid if (identity==fingerprint or identity==name) and name.endswith('('+team+')')]
if len(matches)!=1: raise SystemExit('Choose one exact, valid Developer ID Application certificate fingerprint for the configured team.')
IDENTITY
python3 scripts/release/prepare.py
app='build/release/VayuSetu.app'
ext="$app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension"
codesign --force --timestamp --options runtime --entitlements build/release/Tunnel.entitlements --sign "$VAYU_SIGN_IDENTITY" "$ext"
codesign --force --timestamp --options runtime --entitlements build/release/Safari.entitlements --sign "$VAYU_SIGN_IDENTITY" "$app/Contents/PlugIns/VayuSetuSafari.appex"
codesign --force --timestamp --options runtime --entitlements build/release/Host.entitlements --sign "$VAYU_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/release/verify.py
mkdir -p build/release/DMG dist/release
rm -rf build/release/DMG/VayuSetuVPN.app
rm -rf build/release/DMG/VayuSetu.app
ditto "$app" build/release/DMG/VayuSetu.app
ln -sfn /Applications build/release/DMG/Applications
cp Resources/Install-VPN-Signed.txt 'build/release/DMG/Read Me.txt'
hdiutil create -volname 'VayuSetu' -srcfolder build/release/DMG -format UDZO -ov dist/release/VayuSetu-1.0-macOS.dmg
codesign --force --timestamp --sign "$VAYU_SIGN_IDENTITY" dist/release/VayuSetu-1.0-macOS.dmg
hdiutil verify dist/release/VayuSetu-1.0-macOS.dmg
shasum -a 256 dist/release/VayuSetu-1.0-macOS.dmg > dist/release/VayuSetu-1.0-macOS.dmg.sha256
echo 'Signed DMG prepared. No upload performed. Run notarize.sh explicitly for Apple notarization.'
