from pathlib import Path
import json,subprocess,hashlib,plistlib
p=Path(__file__).resolve().parents[2];group='group.app.vayusetu.shared'
info={'CFBundleName':'VayuSetu Safari','CFBundleDisplayName':'VayuSetu','CFBundlePackageType':'XPC!','VayuAppGroup':group,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.Safari.content-blocker','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler'}}
(p/'Extensions/SafariContentBlocker/Info.plist').write_bytes(plistlib.dumps(info))
(p/'Extensions/SafariContentBlocker/iOS.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':[group]}))
(p/'Extensions/SafariContentBlocker/macOS.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':[group],'com.apple.security.app-sandbox':True}))
q=p/'ios/Configuration/App.entitlements';ent=plistlib.loads(q.read_bytes());ent['com.apple.security.application-groups']=[group];ent['com.apple.developer.networking.networkextension']=['packet-tunnel-provider','dns-settings'];q.write_bytes(plistlib.dumps(ent))
q=p/'ios/VayuSetu.xcodeproj/project.pbxproj';proj=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(q)]));o=proj['objects'];root=o[proj['rootObject']]
def ident(n): return hashlib.sha1(('vayu-safari-'+n).encode()).hexdigest()[:24].upper()
def add(n,v):k=ident(n);o[k]=v;return k
ref=add('source',{'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':'../Extensions/SafariContentBlocker/ContentBlockerRequestHandler.swift','sourceTree':'SOURCE_ROOT'})
build=add('source-build',{'isa':'PBXBuildFile','fileRef':ref})
source=add('sources',{'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':[build],'runOnlyForDeploymentPostprocessing':0})
frameworks=add('frameworks',{'isa':'PBXFrameworksBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0})
product=add('product',{'isa':'PBXFileReference','explicitFileType':'wrapper.app-extension','path':'VayuSetuSafari.appex','sourceTree':'BUILT_PRODUCTS_DIR'})
full=next(v for v in o.values() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='VayuSetuVPN')
base=o[o[full['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings'];cfg=[]
for name in ['Debug','Release']:
 settings={'CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':base['DEVELOPMENT_TEAM'],'PRODUCT_BUNDLE_IDENTIFIER':'app.vayusetu.ios.safari','PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_MODULE_NAME':'VayuSetuSafari','INFOPLIST_FILE':'../Extensions/SafariContentBlocker/Info.plist','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_ENTITLEMENTS':'../Extensions/SafariContentBlocker/iOS.entitlements','MARKETING_VERSION':base['MARKETING_VERSION'],'CURRENT_PROJECT_VERSION':base['CURRENT_PROJECT_VERSION'],'SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','TARGETED_DEVICE_FAMILY':'1,2','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator'}
 cfg.append(add('config-'+name,{'isa':'XCBuildConfiguration','name':name,'buildSettings':settings}))
config=add('config-list',{'isa':'XCConfigurationList','buildConfigurations':cfg,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
target=add('target',{'isa':'PBXNativeTarget','name':'VayuSetuSafari','productName':'VayuSetuSafari','productReference':product,'productType':'com.apple.product-type.app-extension','buildConfigurationList':config,'buildPhases':[source,frameworks],'buildRules':[],'dependencies':[]})

if target not in root['targets']:root['targets'].append(target)
root['attributes']['TargetAttributes'][target]={'DevelopmentTeam':base['DEVELOPMENT_TEAM'],'SystemCapabilities':{'com.apple.ApplicationGroups.iOS':{'enabled':1}}}
proxy=add('proxy',{'isa':'PBXContainerItemProxy','containerPortal':proj['rootObject'],'proxyType':1,'remoteGlobalIDString':target,'remoteInfo':'VayuSetuSafari'})
dep=add('dependency',{'isa':'PBXTargetDependency','target':target,'targetProxy':proxy});
if dep not in full['dependencies']:full['dependencies'].append(dep)
embedbuild=add('embed-build',{'isa':'PBXBuildFile','fileRef':product,'settings':{'ATTRIBUTES':['RemoveHeadersOnCopy']}})
embed=add('embed',{'isa':'PBXCopyFilesBuildPhase','buildActionMask':2147483647,'dstPath':'','dstSubfolderSpec':13,'files':[embedbuild],'name':'Embed Safari Content Blocker','runOnlyForDeploymentPostprocessing':0});
if embed not in full['buildPhases']:full['buildPhases'].append(embed)
if ref not in o['A00000000000000000000003']['children']:o['A00000000000000000000003']['children'].append(ref)
if product not in o['A00000000000000000000004']['children']:o['A00000000000000000000004']['children'].append(product)
for v in o.values():
 if v.get('isa')=='XCBuildConfiguration':
  settings=v.get('buildSettings',{})
  if settings.get('PRODUCT_BUNDLE_IDENTIFIER') in ['app.vayusetu.ios','app.vayusetu.ios.preview']:
   settings['INFOPLIST_KEY_VayuAppGroup']=group
   settings['INFOPLIST_FILE']='Configuration/'+('AppInfo.plist' if settings['PRODUCT_BUNDLE_IDENTIFIER']=='app.vayusetu.ios' else 'PreviewInfo.plist')
   flags=settings.get('OTHER_LDFLAGS',['$(inherited)'])
   if isinstance(flags,str): flags=[flags]
   if '-lsqlite3' not in flags: flags.append('-lsqlite3')
   settings['OTHER_LDFLAGS']=flags
   settings['CURRENT_PROJECT_VERSION']='18';settings['MARKETING_VERSION']='0.11.2'
  if settings.get('PRODUCT_BUNDLE_IDENTIFIER') in ['app.vayusetu.ios.safari','app.vayusetu.ios.tunnel']:
   settings['CURRENT_PROJECT_VERSION']='18';settings['MARKETING_VERSION']='0.11.2'
def encode(x):
 if isinstance(x,dict):return '{\n'+''.join(json.dumps(str(k))+' = '+encode(v)+';\n' for k,v in x.items())+'}'
 if isinstance(x,list):return '('+','.join(encode(v) for v in x)+')'
 if isinstance(x,int):return str(x)
 return json.dumps(str(x))
q.write_text('// !$*UTF8*$!\n'+encode(proj)+'\n')
print('iOS Safari extension target and DNS/App Group entitlements added.')
