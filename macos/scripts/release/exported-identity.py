#!/usr/bin/env python3
"""Return the exact exported Developer ID leaf authorized by both profiles."""
from pathlib import Path
import hashlib,plistlib,subprocess
root=Path(__file__).resolve().parents[2]
app=root/'build/auto-sign/export-provisioned/VayuSetuVPN.app'
ext=app/'Contents/Library/SystemExtensions/app.vayusetu.macos.tunnel.systemextension'
identities=[]
for index,bundle in enumerate([app,ext]):
 prefix=root/'build/auto-sign'/f'export-certificate-{index}-'
 subprocess.run(['codesign','--display','--extract-certificates='+str(prefix),str(bundle)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 leaf=Path(str(prefix)+'0').read_bytes()
 p=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(bundle/'Contents/embedded.provisionprofile')]))
 if leaf not in p.get('DeveloperCertificates',[]): raise SystemExit('Exported signing certificate is not authorized by its provisioning profile')
 identities.append(hashlib.sha1(leaf).hexdigest().upper())
if identities[0]!=identities[1]: raise SystemExit('Host and extension use different signing certificates')
print(identities[0])
