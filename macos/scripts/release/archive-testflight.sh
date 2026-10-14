#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export VAYU_DEVELOPMENT_TEAM="${VAYU_DEVELOPMENT_TEAM:-X4MH29QNRS}"
export VAYU_EXPORT_METHOD=app-store-connect
auth_args=()
if [[ -n "${VAYU_ASC_API_KEY_PATH:-}" || -n "${VAYU_ASC_API_KEY_ID:-}" || -n "${VAYU_ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${VAYU_ASC_API_KEY_PATH:-}" || -z "${VAYU_ASC_API_KEY_ID:-}" || -z "${VAYU_ASC_ISSUER_ID:-}" ]]; then
        echo 'Set VAYU_ASC_API_KEY_PATH, VAYU_ASC_API_KEY_ID, and VAYU_ASC_ISSUER_ID together.' >&2
        exit 2
    fi
    if [[ ! -r "$VAYU_ASC_API_KEY_PATH" ]]; then echo 'App Store Connect API key file is not readable.' >&2; exit 2; fi
    auth_args=(-authenticationKeyPath "$VAYU_ASC_API_KEY_PATH" -authenticationKeyID "$VAYU_ASC_API_KEY_ID" -authenticationKeyIssuerID "$VAYU_ASC_ISSUER_ID")
fi
python3 scripts/release/configure-auto-sign.py
mkdir -p build/testflight/intermediate dist/testflight
xcodebuild -project VayuSetuSigning.xcodeproj -scheme VayuSetuVPN -configuration Release -destination 'platform=macOS' -derivedDataPath build/testflight/derived -archivePath build/testflight/intermediate/VayuSetuVPN.xcarchive CODE_SIGNING_ALLOWED=NO archive > build/testflight/archive.log 2>&1
python3 - <<'PY'
import os,plistlib,subprocess,shutil
from pathlib import Path
app=Path('build/testflight/intermediate/VayuSetuVPN.xcarchive/Products/Applications/VayuSetu.app')
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
shutil.copytree('build/symbols',app.parents[2]/'dSYMs',dirs_exist_ok=True)
for name,bundle in [('Tunnel',ext)]+[('Safari'+x.capitalize(),app/'Contents/PlugIns'/('VayuSetuSafari'+x.capitalize()+'.appex')) for x in ['ads','privacy','security','social','annoyances','custom']]+[('Host',app)]:
 subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(Path('build/auto-sign')/(name+'.entitlements')),str(bundle)],check=True)
Path('build/testflight/ExportOptions.plist').write_bytes(plistlib.dumps({'teamID':os.environ['VAYU_DEVELOPMENT_TEAM'],'method':'app-store-connect','signingStyle':'automatic','destination':'export','manageAppVersionAndBuildNumber':False}))
PY
xcodebuild -exportArchive -archivePath build/testflight/intermediate/VayuSetuVPN.xcarchive -exportOptionsPlist build/testflight/ExportOptions.plist -exportPath dist/testflight -allowProvisioningUpdates ${auth_args[@]+"${auth_args[@]}"} > build/testflight/export.log 2>&1
# Inspect the exported payload, in addition to the signed archive: export applies Store distribution signing.
pkgutil --check-signature dist/testflight/VayuSetu.pkg
verification_dir=$(mktemp -d "${TMPDIR:-/tmp/}vayu-store-verification.XXXXXX")
pkgutil --expand-full dist/testflight/VayuSetu.pkg "$verification_dir/expanded"
python3 - "$verification_dir/expanded" <<'PYVERIFY'
from pathlib import Path
import subprocess,sys
apps=list(Path(sys.argv[1]).rglob('VayuSetu.app'))
if len(apps)!=1:raise ValueError('Expected one exported VPN application')
subprocess.run(['python3','scripts/release/verify-testflight.py',str(apps[0])],check=True)
# Build a usable Organizer archive from the genuinely Store-signed export.
# Derive metadata from its signature rather than filling in an unsigned archive.
import os,plistlib,re,shutil
source=Path('build/testflight/intermediate/VayuSetuVPN.xcarchive')
archive=Path('build/testflight/VayuSetu-macOS.xcarchive')
if archive.exists():shutil.rmtree(archive)
shutil.copytree(source,archive)
app=archive/'Products/Applications/VayuSetu.app'
shutil.rmtree(app)
shutil.copytree(apps[0],app)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
signature=subprocess.run(['codesign','--display','--verbose=4',str(app)],capture_output=True,check=True).stderr.decode()
team=re.search(r'^TeamIdentifier=(.+)$',signature,re.M).group(1)
identity=re.search(r'^Authority=(.+)$',signature,re.M).group(1)
if team!=os.environ['VAYU_DEVELOPMENT_TEAM'] or not identity.startswith('Apple Distribution:'):raise ValueError('Expected paid-team Store distribution signature')
info=plistlib.loads((archive/'Info.plist').read_bytes())
info['Name']='VayuSetu'
info['ApplicationProperties'].update(Team=team,SigningIdentity=identity,ApplicationPath='Applications/VayuSetu.app')
(archive/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['python3','scripts/release/verify-symbols.py',str(archive)],check=True)
print('Store-signed Organizer archive verified:',archive)
PYVERIFY
shasum -a 256 dist/testflight/VayuSetu.pkg > dist/testflight/VayuSetu.pkg.sha256
printf 'macOS App Store Connect export verified. No upload performed.\n' 
