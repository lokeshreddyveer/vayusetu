#!/bin/bash
# Builds the six Safari content-blocker extensions (ads, privacy, security, social, annoyances, custom) into the app bundle.
# Each reads its own rules file from the shared App Group container; see Extensions/SafariContentBlocker.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
app="${1:?app bundle path required}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/safari build/symbols
rm -rf "$app/Contents/PlugIns/VayuSetuSafari.appex"      # the single extension of earlier versions
for name in ads privacy security social annoyances custom; do
    cap="$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}"
    product="VayuSetuSafari$cap"
    ext="$app/Contents/PlugIns/$product.appex"
    rm -rf "$ext"; mkdir -p "$ext/Contents/MacOS" "$ext/Contents/Resources"
    for arch in arm64 x86_64; do
        xcrun swiftc -swift-version 5 -g -O -sdk "$sdk" -target "$arch-apple-macos14.0" -module-cache-path build/module-cache -parse-as-library -emit-executable -application-extension -module-name "$product" ../Extensions/SafariContentBlocker/ContentBlockerRequestHandler.swift -o "build/safari/$product-$arch" -framework Foundation -framework AppKit -framework SafariServices -framework UniformTypeIdentifiers -Xlinker -e -Xlinker _NSExtensionMain
    done
    xcrun lipo -create "build/safari/$product-arm64" "build/safari/$product-x86_64" -output "$ext/Contents/MacOS/$product"
    python3 - "$app" "$product" "$name" "$cap" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]);product,name,cap=sys.argv[2:5]
host=plistlib.loads((app/'Contents/Info.plist').read_bytes())
host['VayuAppGroup']='X4MH29QNRS.app.vayusetu.shared';(app/'Contents/Info.plist').write_bytes(plistlib.dumps(host))
info=plistlib.loads(Path('../Extensions/SafariContentBlocker/Info.plist').read_bytes())
info.update(CFBundleExecutable=product,CFBundleIdentifier=host['CFBundleIdentifier']+'.safari'+name,CFBundleDisplayName='VayuSetu '+cap,CFBundleName='VayuSetu '+cap,
            CFBundleShortVersionString=host['CFBundleShortVersionString'],CFBundleVersion=host['CFBundleVersion'],LSMinimumSystemVersion='14.0')
info['NSExtension']['NSExtensionPrincipalClass']=product+'.ContentBlockerRequestHandler'
info['VayuAppGroup']=host['VayuAppGroup']; info['VayuRulesFile']='safari-rules-'+name+'.json'
info['NSHumanReadableDescription']={'ads':'Blocks advertising in Safari using the filter lists you turn on in VayuSetu.','privacy':'Blocks trackers and analytics in Safari using the filter lists you turn on in VayuSetu.','security':'Blocks malware, scam and cryptomining sites in Safari using the filter lists you turn on in VayuSetu.','social':'Blocks social-media widgets and trackers in Safari using the filter lists you turn on in VayuSetu.','annoyances':'Hides cookie banners and pop-ups in Safari using the filter lists you turn on in VayuSetu.','custom':'Applies your own VayuSetu allow and block rules and imported lists in Safari.'}[name]
(app/'Contents/PlugIns'/(product+'.appex')/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
    python3 - "$product" <<'SYMBOLS'
from pathlib import Path
import shutil,subprocess,sys
product=sys.argv[1]
out=Path('build/symbols')/(product+'.appex.dSYM')
if out.exists():shutil.rmtree(out)
shutil.copytree(f'build/safari/{product}-arm64.dSYM',out)
dwarf=out/'Contents/Resources/DWARF'
for f in dwarf.iterdir():f.unlink()
subprocess.run(['xcrun','lipo','-create',f'build/safari/{product}-arm64.dSYM/Contents/Resources/DWARF/{product}-arm64',f'build/safari/{product}-x86_64.dSYM/Contents/Resources/DWARF/{product}-x86_64','-output',str(dwarf/product)],check=True)
SYMBOLS
    codesign --force --sign - "$ext"
done
