#!/usr/bin/env python3
"""Let Xcode provision and sign the existing universal app and system extension."""
from pathlib import Path
import json, plistlib, os, re
root=Path(__file__).resolve().parents[2]
config=root/'build/auto-sign';config.mkdir(parents=True,exist_ok=True)
proj=root/'VayuSetuSigning.xcodeproj';proj.mkdir(exist_ok=True)
store_distribution=os.environ.get('VAYU_EXPORT_METHOD') == 'app-store-connect'
# The -systemextension entitlement suffix is for Developer ID distribution,
# not the system-extension packaging format. Store profiles use the base value.
network_entitlement='packet-tunnel-provider' if store_distribution else 'packet-tunnel-provider-systemextension'
host_product='VayuSetu' if store_distribution else 'VayuSetuVPN'
team=os.environ.get('VAYU_DEVELOPMENT_TEAM','X4MH29QNRS')
if not re.fullmatch('[A-Z0-9]{10}',team): raise ValueError('Invalid developer team')
bundle='app.vayusetu.macos';group=team+'.app.vayusetu.macos.shared';app_private_group=team+'.'+bundle
app=root/'dist/VayuSetuVPN.app';ext=app/'Contents/Library/SystemExtensions'/(bundle+'.tunnel.systemextension')
# Six Safari content blockers, one per ruleset. App Store validation allows one dot after the host identifier.
SAFARI=['ads','privacy','security','social','annoyances','custom']
def safari_name(x):return 'Safari'+x.capitalize()
bundles=[('Host',app,bundle),('Tunnel',ext,bundle+'.tunnel')]+[(safari_name(x),app/'Contents/PlugIns'/('VayuSetu'+safari_name(x)+'.appex'),bundle+'.safari'+x) for x in SAFARI]
for name,source,identifier in bundles:
 info=plistlib.loads((source/'Contents/Info.plist').read_bytes());info['VayuKeychainGroup']=group
 if name=='Host':info['VayuAppKeychainGroup']=app_private_group
 if name=='Host' and store_distribution: info['LSApplicationCategoryType']='public.app-category.utilities'
 if name=='Host':info['VayuAppGroup']=team+'.app.vayusetu.shared'
 if name=='Tunnel':info['NetworkExtension']['NEMachServiceName']=team+'.'+bundle+'.tunnel'
 (config/(name+'.plist')).write_bytes(plistlib.dumps(info))
 ent={'com.apple.application-identifier':team+'.'+identifier,'com.apple.developer.team-identifier':team,'com.apple.developer.networking.networkextension':[network_entitlement],'keychain-access-groups':[group,app_private_group] if name=='Host' else [group]}
 if name.startswith('Safari'):
  ent={'com.apple.application-identifier':team+'.'+identifier,'com.apple.developer.team-identifier':team,'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':[team+'.app.vayusetu.shared']}
 if name=='Host':
  ent['com.apple.security.application-groups']=[team+'.app.vayusetu.shared']
  ent['com.apple.developer.networking.networkextension'].append('dns-settings')
  ent['com.apple.developer.system-extension.install']=True
  if store_distribution: ent.update({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True,'com.apple.security.files.user-selected.read-write':True})
 elif name=='Tunnel':ent.update({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True})
 (config/(name+'.entitlements')).write_bytes(plistlib.dumps(ent))
objects={};counter=0

def add(isa,body):
 global counter
 counter+=1;k=f'{counter:024X}';objects[k]=f'isa = {isa}; {body}';return k

def q(s):return json.dumps(str(s))
products=add('PBXGroup','children = (); name = Products; sourceTree = "<group>";')
main=add('PBXGroup',f'children = ({products}); sourceTree = "<group>";')
project_id='FFFFFFFFFFFFFFFFFFFFFFFF'

def configs(name,identifier,skip,product):
 settings={'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','ARCHS':'arm64 x86_64','ONLY_ACTIVE_ARCH':'NO','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':team,'PRODUCT_BUNDLE_IDENTIFIER':identifier,'PRODUCT_NAME':product,'INFOPLIST_FILE':f'build/auto-sign/{name}.plist','CODE_SIGN_ENTITLEMENTS':f'build/auto-sign/{name}.entitlements','ENABLE_HARDENED_RUNTIME':'YES','SKIP_INSTALL':skip,'GENERATE_INFOPLIST_FILE':'NO','ALWAYS_SEARCH_USER_PATHS':'NO','INSTALL_PATH':'$(LOCAL_APPS_DIR)' if name=='Host' else '/Library/SystemExtensions'}
 ids=[]
 for mode in ['Debug','Release']:
  ids.append(add('XCBuildConfiguration',f'name = {mode}; buildSettings = {{'+''.join(f'{k} = {q(v)};' for k,v in settings.items())+'};'))
 return add('XCConfigurationList',f'buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

def phase(source):
 # Xcode supplies profiles and code signatures after this phase.
 script='set -eu\nmkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"\n'+f'/usr/bin/ditto {q(source/"Contents/MacOS")} "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS"\n/usr/bin/ditto {q(source/"Contents/Resources")} "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"\n'
 return add('PBXShellScriptBuildPhase',f'buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = {q(script)}; alwaysOutOfDate = 1;')
extref=add('PBXFileReference',f'explicitFileType = "wrapper.system-extension"; path = {q(bundle+".tunnel.systemextension")}; sourceTree = BUILT_PRODUCTS_DIR;')
hostref=add('PBXFileReference',f'explicitFileType = wrapper.application; path = {host_product}.app; sourceTree = BUILT_PRODUCTS_DIR;')
extconfig=configs('Tunnel',bundle+'.tunnel','YES',bundle+'.tunnel')
extphase=phase(ext)
exttarget=add('PBXNativeTarget',f'buildConfigurationList = {extconfig}; buildPhases = ({extphase}); buildRules = (); dependencies = (); name = VayuSetuTunnel; productName = {q(bundle+".tunnel")}; productReference = {extref}; productType = "com.apple.product-type.system-extension";')
proxy=add('PBXContainerItemProxy',f'containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {exttarget}; remoteInfo = VayuSetuTunnel;')
dep=add('PBXTargetDependency',f'target = {exttarget}; targetProxy = {proxy};')
buildfile=add('PBXBuildFile',f'fileRef = {extref}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy);}};')
copy=add('PBXCopyFilesBuildPhase',f'buildActionMask = 2147483647; dstPath = Contents/Library/SystemExtensions; dstSubfolderSpec = 1; files = ({buildfile}); name = "Embed System Extension"; runOnlyForDeploymentPostprocessing = 0;')
safari_refs=[];safari_targets=[];safari_deps=[];safari_builds=[]
for x in SAFARI:
 n=safari_name(x);product='VayuSetu'+n
 ref=add('PBXFileReference',f'explicitFileType = "wrapper.app-extension"; path = {product}.appex; sourceTree = BUILT_PRODUCTS_DIR;')
 cfg=configs(n,bundle+'.safari'+x,'YES',product)
 ph=phase(app/'Contents/PlugIns'/(product+'.appex'))
 tgt=add('PBXNativeTarget',f'buildConfigurationList = {cfg}; buildPhases = ({ph}); buildRules = (); dependencies = (); name = {product}; productName = {product}; productReference = {ref}; productType = "com.apple.product-type.app-extension";')
 prx=add('PBXContainerItemProxy',f'containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {tgt}; remoteInfo = {product};')
 safari_deps.append(add('PBXTargetDependency',f'target = {tgt}; targetProxy = {prx};'))
 safari_builds.append(add('PBXBuildFile',f'fileRef = {ref}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy);}};'))
 safari_refs.append(ref);safari_targets.append(tgt)
safaricopy=add('PBXCopyFilesBuildPhase',f'buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({",".join(safari_builds)}); name = "Embed Safari Content Blockers"; runOnlyForDeploymentPostprocessing = 0;')
SAFARI_DEPS=','.join(safari_deps);SAFARI_REFS=','.join(safari_refs);SAFARI_TARGETS=','.join(safari_targets)
hostconfig=configs('Host',bundle,'NO',host_product)
hostphase=phase(app)
hosttarget=add('PBXNativeTarget',f'buildConfigurationList = {hostconfig}; buildPhases = ({hostphase},{copy},{safaricopy}); buildRules = (); dependencies = ({dep},{SAFARI_DEPS}); name = VayuSetuVPN; productName = VayuSetuVPN; productReference = {hostref}; productType = "com.apple.product-type.application";')
objects[products]=f'isa = PBXGroup; children = ({hostref},{extref},{SAFARI_REFS}); name = Products; sourceTree = "<group>";'
pc=add('XCBuildConfiguration','name = Release; buildSettings = {};')
pcl=add('XCConfigurationList',f'buildConfigurations = ({pc}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
objects[project_id]=f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; TargetAttributes = {{{hosttarget} = {{DevelopmentTeam = {team}; ProvisioningStyle = Automatic;}}; {exttarget} = {{DevelopmentTeam = {team}; ProvisioningStyle = Automatic;}};}};}}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({hosttarget},{exttarget},{SAFARI_TARGETS});'
(proj/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(k+' = {'+v+'};\n' for k,v in objects.items())+'}; rootObject = '+project_id+'; }\n')
schemes=proj/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'VayuSetuVPN.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{hosttarget}" BuildableName="{host_product}.app" BlueprintName="VayuSetuVPN" ReferencedContainer="container:VayuSetuSigning.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Automatic signing project generated for universal host and system extension.')
