#!/usr/bin/env python3
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
rows = []
for scheme in ['VayuSetu', 'VayuSetuVPN']:
    for platform in ['simulator', 'device']:
        app = root / 'dist' / f'{scheme}-{platform}.app'
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] == '0.8.0'
        assert info['MinimumOSVersion'] == '17.0' and info['UIDeviceFamily'] == [1]
        assert (app / 'PrivacyInfo.xcprivacy').exists() and (app / 'ThirdPartyNotices.txt').exists()
        archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(app / info['CFBundleExecutable'])], text=True).strip()
        if platform == 'device':
            assert archs == 'arm64'
        row = f'{scheme}-{platform}: version 0.8.0, iOS 17+, {archs}'
        if scheme == 'VayuSetuVPN':
            ext = app / 'PlugIns/VayuSetuTunnel.appex'
            e = plistlib.loads((ext / 'Info.plist').read_bytes())
            assert e['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.tunnel'
            assert e['NSExtension']['NSExtensionPrincipalClass'] == 'VayuSetuTunnel.PacketTunnelProvider'
            assert e['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.networkextension.packet-tunnel'
            assert (ext / 'PrivacyInfo.xcprivacy').exists() and (ext / 'ThirdPartyNotices.txt').exists()
            # Xcode's debug-dylib mode puts the compiled implementation in an embedded dylib.
            images = [ext / e['CFBundleExecutable']] + list(ext.glob('*.debug.dylib'))
            symbols = ''.join(subprocess.check_output(['nm', '-g', str(image)], text=True, stderr=subprocess.DEVNULL) for image in images)
            assert all(symbol in symbols for symbol in ['_wgTurnOn', '_wgTurnOff', '_wgGetConfig'])
            row += '; embedded extension and linked WireGuard backend verified'
        rows.append(row)
(root / 'dist/BUILD-PRODUCTS.txt').write_text('\n'.join(rows) + '\nUnsigned builds; use Xcode signing for a real iPhone.\n')
print('\n'.join(rows))
