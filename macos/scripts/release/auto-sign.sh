#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export VAYU_DEVELOPMENT_TEAM="${VAYU_DEVELOPMENT_TEAM:-X4MH29QNRS}"
auth_args=()
if [[ -n "${VAYU_ASC_API_KEY_PATH:-}" ]]; then
    : "${VAYU_ASC_API_KEY_ID:?Set API key ID}"; : "${VAYU_ASC_ISSUER_ID:?Set API issuer ID}"
    auth_args=(-authenticationKeyPath "$VAYU_ASC_API_KEY_PATH" -authenticationKeyID "$VAYU_ASC_API_KEY_ID" -authenticationKeyIssuerID "$VAYU_ASC_ISSUER_ID")
fi
python3 scripts/release/configure-auto-sign.py
# Archive existing universal binaries. Xcode's distribution export provisions both targets.
xcodebuild -project VayuSetuSigning.xcodeproj -scheme VayuSetuVPN -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/auto-sign-derived -archivePath build/auto-sign/VayuSetuVPN.xcarchive CODE_SIGNING_ALLOWED=NO archive > build/auto-sign/unsigned-archive.log 2>&1
python3 - <<'PY'
import os,plistlib,subprocess,re
from pathlib import Path
app=Path('build/auto-sign/VayuSetuVPN.xcarchive/Products/Applications/VayuSetuVPN.app')
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
# Preserve capabilities so distribution export requests profiles for restricted entitlements.
for name,bundle in [('Tunnel',ext)]+[('Safari'+x.capitalize(),app/'Contents/PlugIns'/('VayuSetuSafari'+x.capitalize()+'.appex')) for x in ['ads','privacy','security','social','annoyances','custom']]+[('Host',app)]:
 subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(Path('build/auto-sign')/(name+'.entitlements')),str(bundle)],check=True)
identities=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True)
candidates=[fp for fp,name in re.findall(r'\b([0-9A-F]{40}) "(Developer ID Application:[^\"]+)"',identities) if name.endswith('('+os.environ['VAYU_DEVELOPMENT_TEAM']+')')]
if not candidates:raise RuntimeError('No local Developer ID Application private-key identity available')
certificate=os.environ.get('VAYU_SIGN_IDENTITY',candidates[0])
if certificate not in candidates:raise RuntimeError('Requested Developer ID identity is not available for this team')
Path('build/auto-sign/ExportOptions.plist').write_bytes(plistlib.dumps({'teamID':os.environ['VAYU_DEVELOPMENT_TEAM'],'method':'developer-id','signingStyle':'automatic','signingCertificate':certificate,'destination':'export'}))
PY
xcodebuild -exportArchive -archivePath build/auto-sign/VayuSetuVPN.xcarchive -exportOptionsPlist build/auto-sign/ExportOptions.plist -exportPath build/auto-sign/export-provisioned -allowProvisioningUpdates ${auth_args[@]+"${auth_args[@]}"} > build/auto-sign/export-provisioned.log 2>&1
export VAYU_APP_PROFILE="$PWD/build/auto-sign/export-provisioned/VayuSetuVPN.app/Contents/embedded.provisionprofile"
export VAYU_SAFARI_PROFILE="$PWD/build/auto-sign/export-provisioned/VayuSetuVPN.app/Contents/PlugIns/VayuSetuSafari.appex/Contents/embedded.provisionprofile"
export VAYU_TUNNEL_PROFILE="$PWD/build/auto-sign/export-provisioned/VayuSetuVPN.app/Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension/Contents/embedded.provisionprofile"
# Select the exported leaf certificate by fingerprint, avoiding duplicate certificate names.
identity=$(python3 scripts/release/exported-identity.py)
export VAYU_SIGN_IDENTITY="$identity"
# Refuse to produce a VPN release unless Apple's profiles authorize its exact capabilities.
bash scripts/release/sign.sh
