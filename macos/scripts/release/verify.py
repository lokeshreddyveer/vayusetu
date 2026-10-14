import os
from pathlib import Path
import plistlib
import subprocess

root=Path(__file__).resolve().parents[2]
app=root/'build/release/VayuSetu.app'
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
team=os.environ['VAYU_DEVELOPMENT_TEAM']
safari=app/'Contents/PlugIns/VayuSetuSafari.appex'
for bundle in [app,ext,safari]:
 result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(bundle)],capture_output=True,check=True)
 text=result.stderr.decode()
 if f'TeamIdentifier={team}\n' not in text or 'Authority=Developer ID Application:' not in text: raise SystemExit('Signed identity does not match the provisioned Developer ID team')
 ent=plistlib.loads(subprocess.check_output(['/usr/bin/codesign','--display','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
 if ent.get('get-task-allow',False): raise SystemExit('Debugging entitlement is forbidden in release')
 if bundle!=safari and 'packet-tunnel-provider-systemextension' not in ent.get('com.apple.developer.networking.networkextension',[]): raise SystemExit('Missing signed network entitlement')
 expected_groups=[team+'.app.vayusetu.macos.shared']+([team+'.app.vayusetu.macos'] if bundle==app else [])
 if bundle!=safari and ent.get('keychain-access-groups')!=expected_groups: raise SystemExit('Wrong app-only/shared Keychain groups')
 if bundle==app:
  info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
  if info.get('VayuAppKeychainGroup')!=team+'.app.vayusetu.macos': raise SystemExit('Missing app-only Keychain group identifier')
 if bundle!=safari and not (bundle/'Contents/embedded.provisionprofile').exists(): raise SystemExit('Provisioning profile not embedded')
 if bundle in [app,safari] and ent.get('com.apple.security.application-groups') != [team+'.app.vayusetu.shared']: raise SystemExit('Wrong platform App Group container')
 if bundle==app and 'dns-settings' not in ent.get('com.apple.developer.networking.networkextension',[]): raise SystemExit('Missing DNS settings entitlement')
print('All three Developer ID signatures, platform App Groups, network capabilities and profiles verified.')
