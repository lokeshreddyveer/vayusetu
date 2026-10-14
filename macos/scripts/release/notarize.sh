#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
version=$(python3 -c 'import plistlib; print(plistlib.load(open("build/release/VayuSetu.app/Contents/Info.plist","rb"))["CFBundleShortVersionString"])')
dmg="dist/release/VayuSetu-$version-macOS.dmg"
auth_args=()
if [[ -n "${VAYU_ASC_API_KEY_PATH:-}" ]]; then
    : "${VAYU_ASC_API_KEY_ID:?Set key ID}"; : "${VAYU_ASC_ISSUER_ID:?Set issuer ID}"
    auth_args=(--key "$VAYU_ASC_API_KEY_PATH" --key-id "$VAYU_ASC_API_KEY_ID" --issuer "$VAYU_ASC_ISSUER_ID")
else
    : "${VAYU_NOTARY_PROFILE:?Set a notary Keychain profile or App Store Connect key variables}"
    auth_args=(--keychain-profile "$VAYU_NOTARY_PROFILE")
fi
codesign --verify --strict "$dmg"
xcrun notarytool submit "$dmg" "${auth_args[@]}" --wait --output-format json > build/release/notary-result.json
python3 - <<'PY'
import json
result=json.load(open('build/release/notary-result.json'))
if result.get('status')!='Accepted': raise SystemExit('Notarization was not accepted. Inspect build/release/notary-result.json and fetch the Apple log before retrying.')
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
echo 'Notarization accepted; ticket stapled and validated.'
