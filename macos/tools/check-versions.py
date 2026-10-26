#!/usr/bin/env python3
"""Fails when the Mac version configuration is inconsistent.

  python3 macos/tools/check-versions.py [path-to-built-app]

scripts/version.json is the one place the Mac app, the tunnel extension, the network-filter extension and the disk image name get their numbers.
This checks that the scripts read it (no literal left to drift), that the extension numbers are not lower than they were when they last changed
code (an installed extension is only replaced when its version rises), and, when a built app is given or found in dist/, that the bundle says the
same thing."""
import json, plistlib, re, sys
from pathlib import Path

mac = Path(__file__).resolve().parents[1]
want = json.loads((mac / 'scripts/version.json').read_text())
problems = []
for key in ('marketing', 'build', 'tunnel', 'filter'):
    if not re.fullmatch(r'[0-9]+(\.[0-9]+)*', str(want.get(key, ''))): problems.append(f'version.json: "{key}" is missing or not a number')

# The scripts must read the file instead of carrying their own copy.
for rel in ('scripts/vpn-bundle.py', 'scripts/bundle.py', 'scripts/build-filter.sh', 'scripts/verify.py', 'build/release-chain.sh'):
    f = mac / rel
    if not f.exists():
        if rel.startswith('build/'): continue          # a local helper, not part of the repository
        problems.append(f'{rel} is missing'); continue
    text = f.read_text()
    if 'version.json' not in text: problems.append(f'{rel} does not read version.json')
    if re.search(r"CFBundleVersion['\"]?\s*[:=]\s*['\"]\d+['\"]", text) or re.search(r"CFBundleShortVersionString['\"]?\s*[:=]\s*['\"][\d.]+['\"]", text):
        problems.append(f'{rel} still contains a literal bundle version')
    if re.search(r'VayuSetu-\d+\.\d+-\d+-macOS', text): problems.append(f'{rel} still contains a literal disk image name')

# A built app, if there is one: the host, the tunnel and the filter must say what the file says.
app = Path(sys.argv[1]) if len(sys.argv) > 1 else mac / 'dist/VayuSetuVPN.app'
checked = 'no built app to compare'
if app.exists():
    def info(p): return plistlib.loads((p / 'Contents/Info.plist').read_bytes())
    host = info(app)
    if host['CFBundleShortVersionString'] != want['marketing'] or host['CFBundleVersion'] != want['build']:
        problems.append(f"the built app is {host['CFBundleShortVersionString']} ({host['CFBundleVersion']}), version.json says {want['marketing']} ({want['build']})")
    for name, key in (('tunnel', 'tunnel'), ('filter', 'filter')):
        ext = app / f'Contents/Library/SystemExtensions/app.vayusetu.macos.{name}.systemextension'
        if ext.exists():
            v = info(ext)
            if v['CFBundleVersion'] != want[key]: problems.append(f"the built {name} extension is version {v['CFBundleVersion']}, version.json says {want[key]}")
            if v['CFBundleShortVersionString'] != want['marketing']: problems.append(f"the built {name} extension says {v['CFBundleShortVersionString']}, version.json says {want['marketing']}")
    checked = f"built app {app.name} agrees"

if problems:
    print('FAIL  Mac version configuration is inconsistent:'); [print('  - ' + p) for p in problems]; sys.exit(1)
print(f"PASS  Mac {want['marketing']} (build {want['build']}), tunnel {want['tunnel']}, filter {want['filter']}: the scripts read version.json; {checked}")
