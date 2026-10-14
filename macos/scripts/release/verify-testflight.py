"""Validate the exported Store-signed app, including its embedded system extension."""
import datetime as dt
import os
from pathlib import Path
import plistlib
import subprocess
import sys

app=Path(sys.argv[1])
team=os.environ.get('VAYU_DEVELOPMENT_TEAM','X4MH29QNRS')
identifier='app.vayusetu.macos'
ext=app/'Contents/Library/SystemExtensions'/f'{identifier}.tunnel.systemextension'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
for bundle,expected in [(app,identifier),(ext,identifier+'.tunnel')]:
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier']!=expected:raise ValueError('Unexpected bundle identifier')
    if bundle==ext and not info.get('NSSystemExtensionUsageDescription','').strip():raise ValueError('System-extension usage description is missing')
    ent=plistlib.loads(subprocess.check_output(['codesign','--display','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
    profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(bundle/'Contents/embedded.provisionprofile')],stderr=subprocess.DEVNULL))
    authorized=profile['Entitlements']
    expected_ne=['packet-tunnel-provider','dns-settings'] if bundle==app else ['packet-tunnel-provider']
    if sorted(ent.get('com.apple.developer.networking.networkextension',[]))!=sorted(expected_ne):raise ValueError('Wrong Store network entitlement')
    if not set(expected_ne)<=set(authorized.get('com.apple.developer.networking.networkextension',[])):raise ValueError('Profile does not authorize the network entitlements')
    for value in [ent,authorized]:
        if value.get('com.apple.application-identifier')!=team+'.'+expected:raise ValueError('Application identity mismatch')
        if value.get('get-task-allow',False):raise ValueError('Debugging is enabled')
    if team not in profile.get('TeamIdentifier',[]):raise ValueError('Wrong profile team')
    if profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc)<=dt.datetime.now(dt.timezone.utc):raise ValueError('Expired profile')
    expected_groups=[team+'.app.vayusetu.macos.shared']+([team+'.app.vayusetu.macos'] if bundle==app else [])
    if ent.get('keychain-access-groups')!=expected_groups:raise ValueError('Wrong app-only/shared Keychain groups')
    if bundle==app and info.get('VayuAppKeychainGroup')!=team+'.app.vayusetu.macos':raise ValueError('App-only Keychain group is missing from the app')
    if not ent.get('com.apple.security.app-sandbox'):raise ValueError('Store target is not sandboxed')
    if bundle==app and not ent.get('com.apple.developer.system-extension.install'):raise ValueError('System-extension installation is missing')
    print(expected+': signed Store entitlement, identity, sandbox and Apple profile verified.')

# The six Safari content blockers: identity, sandbox, shared App Group and a matching version.
host=plistlib.loads((app/'Contents/Info.plist').read_bytes())
for name in ['ads','privacy','security','social','annoyances','custom']:
    bundle=app/'Contents/PlugIns'/f'VayuSetuSafari{name.capitalize()}.appex'
    if not bundle.exists():raise ValueError(f'Missing Safari extension: {name}')
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    expected=f'{identifier}.safari{name}'
    if info['CFBundleIdentifier']!=expected:raise ValueError('Unexpected Safari extension identifier')
    if info.get('VayuRulesFile')!=f'safari-rules-{name}.json':raise ValueError('Safari extension rules file mismatch')
    if info['CFBundleVersion']!=host['CFBundleVersion'] or info['CFBundleShortVersionString']!=host['CFBundleShortVersionString']:raise ValueError('Safari extension version mismatch')
    ent=plistlib.loads(subprocess.check_output(['codesign','--display','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
    if not ent.get('com.apple.security.app-sandbox'):raise ValueError('Safari extension is not sandboxed')
    if ent.get('com.apple.security.application-groups')!=[team+'.app.vayusetu.shared']:raise ValueError('Safari extension App Group mismatch')
    if ent.get('com.apple.application-identifier')!=team+'.'+expected:raise ValueError('Safari extension identity mismatch')
    print(expected+': signed, sandboxed, shared App Group and version verified.')
