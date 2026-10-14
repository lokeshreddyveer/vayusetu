import datetime as dt
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

TEAM=os.environ['VAYU_DEVELOPMENT_TEAM']
ROOT=Path(__file__).resolve().parents[2]
ID='app.vayusetu.macos'
GROUP=TEAM+'.app.vayusetu.macos.shared'
APP_PRIVATE_GROUP=TEAM+'.'+ID


def profile(path, identifier, host):
    raw=subprocess.check_output(['/usr/bin/security','cms','-D','-i',str(path)])
    value=plistlib.loads(raw)
    ent=value.get('Entitlements',{})
    if TEAM not in value.get('TeamIdentifier',[]): raise ValueError('Wrong team in provisioning profile')
    if value['ExpirationDate'].replace(tzinfo=dt.timezone.utc) <= dt.datetime.now(dt.timezone.utc): raise ValueError('Expired provisioning profile')
    application=ent.get('com.apple.application-identifier',ent.get('application-identifier',''))
    if application != TEAM+'.'+identifier: raise ValueError('Provisioning profile belongs to a different application')
    if identifier.endswith('.safari'):
        if ent.get('get-task-allow',False): raise ValueError('Safari requires a distribution profile')
        return {'com.apple.application-identifier':TEAM+'.'+identifier,'com.apple.developer.team-identifier':TEAM,'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':[TEAM+'.app.vayusetu.shared']}
    if 'packet-tunnel-provider-systemextension' not in ent.get('com.apple.developer.networking.networkextension',[]): raise ValueError('System-extension entitlement is missing from profile')
    if host and ('dns-settings' not in ent.get('com.apple.developer.networking.networkextension',[])): raise ValueError('Host profile does not authorize encrypted DNS and Safari sharing')
    groups=ent.get('keychain-access-groups',[])
    required=[GROUP,APP_PRIVATE_GROUP] if host else [GROUP]
    if any(not any(group==item or (group.endswith('.*') and item.startswith(group[:-1])) for group in groups) for item in required): raise ValueError('Required app-only/shared Keychain group is not authorized by profile')
    if host and not ent.get('com.apple.developer.system-extension.install',False): raise ValueError('System-extension installation is not authorized')
    if ent.get('get-task-allow',False): raise ValueError('Use a distribution profile, not a debugging profile')
    return {
        'com.apple.application-identifier': TEAM+'.'+identifier,
        'com.apple.developer.team-identifier': TEAM,
        'com.apple.developer.networking.networkextension':['packet-tunnel-provider-systemextension'],
        'keychain-access-groups':required,
    }


def main():
    if not re.fullmatch('[A-Z0-9]{10}',TEAM): raise ValueError('Invalid team ID')
    app_profile=Path(os.environ['VAYU_APP_PROFILE']).expanduser()
    ext_profile=Path(os.environ['VAYU_TUNNEL_PROFILE']).expanduser()
    app_ent=profile(app_profile,ID,True)
    ext_ent=profile(ext_profile,ID+'.tunnel',False)
    app_ent['com.apple.developer.system-extension.install']=True
    app_ent['com.apple.security.application-groups']=[TEAM+'.app.vayusetu.shared']
    app_ent['com.apple.developer.networking.networkextension'].append('dns-settings')
    safari_profile=Path(os.environ['VAYU_SAFARI_PROFILE']).expanduser()
    safari_ent=profile(safari_profile,ID+'.safari',False)
    ext_ent.update({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True})
    source=ROOT/'dist/VayuSetuVPN.app'
    release=ROOT/'build/release'
    release.mkdir(parents=True,exist_ok=True)
    app=release/'VayuSetu.app'
    if app.exists(): shutil.rmtree(app)
    shutil.copytree(source,app)
    ext=app/'Contents/Library/SystemExtensions'/((ID+'.tunnel')+'.systemextension')
    safari=app/'Contents/PlugIns/VayuSetuSafari.appex'
    for bundle,p in [(app,app_profile),(ext,ext_profile),(safari,safari_profile)]:
        shutil.copy2(p,bundle/'Contents/embedded.provisionprofile')
        info_path=bundle/'Contents/Info.plist'
        info=plistlib.loads(info_path.read_bytes());info['VayuKeychainGroup']=GROUP
        if bundle==app:info['VayuAppKeychainGroup']=APP_PRIVATE_GROUP
        if bundle==app or bundle==safari:info['VayuAppGroup']=TEAM+'.app.vayusetu.shared'
        if bundle==ext: info['NetworkExtension']['NEMachServiceName']=TEAM+'.'+ID+'.tunnel'
        info_path.write_bytes(plistlib.dumps(info))
    (release/'Host.entitlements').write_bytes(plistlib.dumps(app_ent))
    (release/'Tunnel.entitlements').write_bytes(plistlib.dumps(ext_ent))
    (release/'Safari.entitlements').write_bytes(plistlib.dumps(safari_ent))
    print('Provisioning profiles validated; release bundle prepared.')

if __name__=='__main__': main()
