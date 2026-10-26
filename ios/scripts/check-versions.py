#!/usr/bin/env python3
"""Fails when the iPhone project's version differs from ios/Configuration/Version.json in any target or configuration.

  python3 ios/scripts/check-versions.py

The project file, the configure scripts and verify.py must all agree with that one file; this reads the project as it is, so a script that
overwrote it with a stale number, or a hand edit in Xcode, is caught here instead of at release time."""
import json, plistlib, subprocess, sys
from collections import Counter
from pathlib import Path

ios = Path(__file__).resolve().parents[1]
want = json.loads((ios / 'Configuration/Version.json').read_text())
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ios / 'VayuSetu.xcodeproj/project.pbxproj')]))
marketing, build = Counter(), Counter()
for obj in project['objects'].values():
    if obj.get('isa') == 'XCBuildConfiguration':
        s = obj.get('buildSettings', {})
        if 'MARKETING_VERSION' in s: marketing[str(s['MARKETING_VERSION'])] += 1
        if 'CURRENT_PROJECT_VERSION' in s: build[str(s['CURRENT_PROJECT_VERSION'])] += 1
problems = []
if set(marketing) != {want['marketing']}: problems.append(f"MARKETING_VERSION in the project is {dict(marketing)}, Version.json says {want['marketing']}")
if set(build) != {want['build']}: problems.append(f"CURRENT_PROJECT_VERSION in the project is {dict(build)}, Version.json says {want['build']}")
for script in ['configure-project.py', 'configure-privacy.py', 'verify.py']:
    text = (ios / 'scripts' / script).read_text()
    if 'Version.json' not in text: problems.append(f'{script} does not read Version.json')
    for stale in ('0.8.0', '0.11.2'):
        if f"'{stale}'" in text or f'"{stale}"' in text: problems.append(f'{script} still contains the number {stale}')
if problems:
    print('FAIL  iPhone version configuration is inconsistent:'); [print('  - ' + p) for p in problems]; sys.exit(1)
print(f"PASS  every iPhone target and configuration is version {want['marketing']} ({want['build']}), and the scripts read it from Version.json")
