"""Reject archives with missing extension disclosure or mismatched debug symbols."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

archive = Path(sys.argv[1])
app = archive / 'Products/Applications/VayuSetu.app'
extension = app / 'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
description = plistlib.loads((extension / 'Contents/Info.plist').read_bytes()).get('NSSystemExtensionUsageDescription', '')
if not isinstance(description, str) or not description.strip():
    raise ValueError('System extension usage description is required')

def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    return set(re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)', output))

safari = [(app/'Contents/PlugIns'/f'VayuSetuSafari{x.capitalize()}.appex', f'VayuSetuSafari{x.capitalize()}') for x in ['ads', 'privacy', 'security', 'social', 'annoyances', 'custom']]
for bundle, executable in [(app, 'VayuSetuVPN'), (extension, 'VayuSetuTunnel')] + safari:
    binary = bundle / 'Contents/MacOS' / executable
    symbols = archive / 'dSYMs' / (bundle.name + '.dSYM')
    expected = uuids(binary)
    actual = uuids(symbols)
    if len(expected) != 2 or {arch for _, arch in expected} != {'arm64', 'x86_64'} or actual != expected:
        raise ValueError(f'Missing or mismatched universal symbols for {bundle.name}')
    debug_info = subprocess.check_output(['xcrun', 'dwarfdump', '--debug-info', str(symbols)], text=True)
    if 'DW_TAG_compile_unit' not in debug_info or 'DW_TAG_subprogram' not in debug_info:
        raise ValueError(f'No real debugging information for {bundle.name}')
    print(f'Verified both architecture UUIDs and debugging information: {bundle.name}')
