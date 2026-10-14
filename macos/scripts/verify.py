from pathlib import Path
import plistlib
import subprocess
import re
root=Path(__file__).resolve().parents[1]
# bundle.py defines the version; a literal here drifted from it (0.5.0 vs 0.6.2).
expected=re.search(r"'CFBundleShortVersionString':'([^']+)'",(Path(__file__).parent/'bundle.py').read_text()).group(1)
for name,exe in [('VayuSetu','VayuSetu'),('VayuSetuVPN','VayuSetuVPN')]:
 app=root/'dist'/(name+'.app')
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 assert info['CFBundleShortVersionString']==expected, 'Bundle version differs from bundle.py'
 assert set(subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS'/exe)]).decode().split())=={'arm64','x86_64'}
 assert (app/'Contents/Resources/AppIcon.icns').stat().st_size > 10000
 assert not (app/'Contents/embedded.provisionprofile').exists(), 'Local builds should remain unprovisioned'
 print(name+': universal signed local bundle verified')
app=root/'dist/VayuSetuVPN.app'
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
info=plistlib.loads((ext/'Contents/Info.plist').read_bytes())
assert info['CFBundlePackageType']=='SYSX'
assert info['NetworkExtension']['NEProviderClasses']['com.apple.networkextension.packet-tunnel']=='VayuSetuTunnel.PacketTunnelProvider'
binary=ext/'Contents/MacOS/VayuSetuTunnel'
assert set(subprocess.check_output(['lipo','-archs',str(binary)]).decode().split())=={'arm64','x86_64'}
symbols=subprocess.check_output(['nm','-arch','arm64',str(binary)]).decode()
for name in ['PacketTunnelProvider','wgTurnOn','wgTurnOff']:
 assert name in symbols, 'Missing implementation symbol: '+name
print('Embedded WireGuard system extension and bridge verified; activation remains signing-gated')
