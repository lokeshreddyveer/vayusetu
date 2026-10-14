import plistlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]
app=root/'dist/VayuSetuVPN.app'
info=plistlib.loads((root/'dist/VayuSetu.app/Contents/Info.plist').read_bytes())
info.update(CFBundleExecutable='VayuSetuVPN',CFBundleIdentifier='app.vayusetu.macos',CFBundleName='VayuSetu',CFBundleDisplayName='VayuSetu',CFBundleShortVersionString='1.0',CFBundleVersion='13',VayuStorageDirectory='VayuSetuVPN')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
info={'CFBundleName':'VayuSetu Tunnel','CFBundleDisplayName':'VayuSetu Tunnel','CFBundleIdentifier':'app.vayusetu.macos.tunnel','CFBundleExecutable':'VayuSetuTunnel','NSSystemExtensionUsageDescription':'VayuSetu uses this network extension to route network traffic through your configured VPN.','CFBundlePackageType':'SYSX','CFBundleVersion':'13','CFBundleShortVersionString':'1.0','LSMinimumSystemVersion':'14.0','NetworkExtension':{'NEMachServiceName':'SIGNING_TEAM_REQUIRED.app.vayusetu.macos.tunnel','NEProviderClasses':{'com.apple.networkextension.packet-tunnel':'VayuSetuTunnel.PacketTunnelProvider'}}}
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
