#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
team="${VAYU_DEVELOPMENT_TEAM:-}"
method="${VAYU_EXPORT_METHOD:-debugging}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'Set VAYU_DEVELOPMENT_TEAM to your provisioned Apple Developer team ID.' >&2
    exit 2
fi
if [[ "$method" != debugging && "$method" != app-store-connect && "$method" != release-testing ]]; then
    echo 'Choose debugging, release-testing, or app-store-connect export.' >&2
    exit 2
fi
bash scripts/test.sh
mkdir -p build/release dist/release
xcodebuild -project VayuSetu.xcodeproj -scheme VayuSetuVPN -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/release/derived -archivePath build/release/VayuSetu.xcarchive DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates archive > build/release/archive.log 2>&1
python3 - <<'ARCHIVE_NAME'
from pathlib import Path
import plistlib
p=Path('build/release/VayuSetu.xcarchive/Info.plist')
info=plistlib.loads(p.read_bytes());info['Name']='VayuSetu'
p.write_bytes(plistlib.dumps(info))
ARCHIVE_NAME
app=build/release/VayuSetu.xcarchive/Products/Applications/VayuSetuVPN.app
codesign --verify --deep --strict "$app"
python3 scripts/release/verify-signing.py "$app" "$team"
python3 - "$team" "$method" <<'PY'
import plistlib, sys
from pathlib import Path
Path('build/release/ExportOptions.plist').write_bytes(plistlib.dumps({'teamID':sys.argv[1], 'method':sys.argv[2], 'signingStyle':'automatic', 'destination':'export', 'stripSwiftSymbols':True}))
PY
xcodebuild -exportArchive -archivePath build/release/VayuSetu.xcarchive -exportOptionsPlist build/release/ExportOptions.plist -exportPath dist/release -allowProvisioningUpdates > build/release/export.log 2>&1
printf 'Signed archive validated. Export: dist/release. No upload performed.\n'
