#!/usr/bin/env python3
from pathlib import Path
import plistlib, subprocess, sys
app=Path(sys.argv[1]); team=sys.argv[2]
host_info=plistlib.loads((app/'Info.plist').read_bytes())
assert host_info.get('VayuAppGroup')=='group.app.vayusetu.shared', 'Shared container metadata missing'
assert host_info.get('VayuKeychainGroup')==team+'.app.vayusetu.ios.shared', 'Runtime shared Keychain metadata missing'
assert host_info.get('VayuAppKeychainGroup')==team+'.app.vayusetu.ios', 'Runtime private Keychain metadata missing'
# The six Safari content blockers, the tunnel and the Live Activity are all discovered, never hard-coded.
plugins=sorted((app/'PlugIns').glob('*.appex'))
assert any('Tunnel' in b.name for b in plugins) and sum('Safari' in b.name for b in plugins)==6, 'Expected the tunnel and six Safari extensions'
for bundle in [app]+plugins:
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    info=plistlib.loads((bundle/'Info.plist').read_bytes())
    assert info['CFBundleVersion']==host_info['CFBundleVersion'], 'Extension build version mismatch'
    assert info['CFBundleShortVersionString']==host_info['CFBundleShortVersionString'], 'Extension release version mismatch'
    raw=subprocess.check_output(['codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL)
    ent=plistlib.loads(raw)
    assert ent.get('com.apple.developer.team-identifier')==team, 'Unexpected signing team'
    profile=bundle/'embedded.mobileprovision'
    assert profile.exists(), 'Missing provisioning profile'
    provision=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]))
    assert team in provision['TeamIdentifier'], 'Provisioning team mismatch'
    authorized=provision['Entitlements']
    if bundle==app or 'Tunnel' in bundle.name:
        for values in [ent,authorized]:
            assert 'packet-tunnel-provider' in values.get('com.apple.developer.networking.networkextension',[]), 'Missing packet tunnel entitlement authorization'
        assert any(group.endswith('app.vayusetu.ios.shared') for group in ent.get('keychain-access-groups',[])), 'Missing shared Keychain group'
    if bundle==app:
        for values in [ent,authorized]: assert 'dns-settings' in values.get('com.apple.developer.networking.networkextension',[]), 'DNS settings not authorized'
    if bundle==app or 'Safari' in bundle.name or 'Activity' in bundle.name:
        for values in [ent,authorized]: assert 'group.app.vayusetu.shared' in values.get('com.apple.security.application-groups',[]), 'Shared Safari App Group not authorized'
print('Host, tunnel, six Safari extensions and Live Activity signatures, profiles, versions and capabilities verified.')
