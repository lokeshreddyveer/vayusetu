import json
import plistlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]
VERSION=json.loads((Path(__file__).resolve().parent/'version.json').read_text())   # the one place the Mac version lives
app=root/'dist/VayuSetuVPN.app'
info=plistlib.loads((root/'dist/VayuSetu.app/Contents/Info.plist').read_bytes())
info.update(CFBundleExecutable='VayuSetuVPN',CFBundleIdentifier='app.vayusetu.macos',CFBundleName='VayuSetu',CFBundleDisplayName='VayuSetu',CFBundleShortVersionString=VERSION['marketing'],CFBundleVersion=VERSION['build'],NSSupportsAutomaticTermination=False,NSSupportsSuddenTermination=False,NSLocalNetworkUsageDescription='VayuSetu lists devices on your network that advertise services (printers, speakers, computers) when you open Connection Health. It never connects to them.',NSBonjourServices=['_airplay._tcp','_raop._tcp','_ipp._tcp','_printer._tcp','_http._tcp','_smb._tcp','_afpovertcp._tcp','_ssh._tcp','_workstation._tcp','_homekit._tcp','_googlecast._tcp','_spotify-connect._tcp','_companion-link._tcp'],VayuStorageDirectory='VayuSetuVPN',CFBundleURLTypes=[{'CFBundleURLName':'app.vayusetu.macos.control','CFBundleURLSchemes':['vayusetu']}])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
info={'CFBundleName':'VayuSetu Tunnel','CFBundleDisplayName':'VayuSetu Tunnel','CFBundleIdentifier':'app.vayusetu.macos.tunnel','CFBundleExecutable':'VayuSetuTunnel','NSSystemExtensionUsageDescription':'VayuSetu uses this network extension to route network traffic through your configured VPN.','CFBundlePackageType':'SYSX','CFBundleVersion':VERSION['tunnel'],'CFBundleShortVersionString':VERSION['marketing'],'LSMinimumSystemVersion':'14.0','NetworkExtension':{'NEMachServiceName':'SIGNING_TEAM_REQUIRED.app.vayusetu.macos.tunnel','NEProviderClasses':{'com.apple.networkextension.packet-tunnel':'VayuSetuTunnel.PacketTunnelProvider'}}}
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
