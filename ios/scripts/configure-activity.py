from pathlib import Path
import json,subprocess,hashlib,plistlib
p=Path(__file__).resolve().parents[2];path=p/'ios/VayuSetu.xcodeproj/project.pbxproj'
proj=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]));o=proj['objects'];root=o[proj['rootObject']]
def add(n,v):k=hashlib.sha1(('vayu-activity-'+n).encode()).hexdigest()[:24].upper();o[k]=v;return k
full=next(v for v in o.values() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='VayuSetuVPN')
appTargets=[v for v in o.values() if v.get('isa')=='PBXNativeTarget' and v.get('name') in ['VayuSetu','VayuSetuVPN']]
shared=add('attributes-ref',{'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':'../Extensions/LiveActivity/ConnectionActivityAttributes.swift','sourceTree':'SOURCE_ROOT'})
controller=add('controller-ref',{'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':'Sources/ConnectionActivity.swift','sourceTree':'SOURCE_ROOT'})
widget=add('widget-ref',{'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':'../Extensions/LiveActivity/ConnectionActivityWidget.swift','sourceTree':'SOURCE_ROOT'})
for target in appTargets:
 for ref in [shared,controller]:
  entry=add(target['name']+ref,{'isa':'PBXBuildFile','fileRef':ref})
  for phase in target['buildPhases']:
   if o[phase]['isa']=='PBXSourcesBuildPhase' and entry not in o[phase]['files']:o[phase]['files'].append(entry)
 for config in o[target['buildConfigurationList']]['buildConfigurations']:o[config]['buildSettings']['INFOPLIST_KEY_NSSupportsLiveActivities']='YES'
source=add('sources',{'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':[add('widget-build',{'isa':'PBXBuildFile','fileRef':widget}),add('attributes-build',{'isa':'PBXBuildFile','fileRef':shared})],'runOnlyForDeploymentPostprocessing':0})
product=add('product',{'isa':'PBXFileReference','explicitFileType':'wrapper.app-extension','path':'VayuSetuActivity.appex','sourceTree':'BUILT_PRODUCTS_DIR'})
base=o[o[full['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings'];cfg=[]
info={'CFBundleName':'VayuSetu Activity','CFBundleDisplayName':'VayuSetu','CFBundlePackageType':'XPC!','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
(p/'Extensions/LiveActivity/Info.plist').write_bytes(plistlib.dumps(info))
for name in ['Debug','Release']:
 cfg.append(add('config-'+name,{'isa':'XCBuildConfiguration','name':name,'buildSettings':{'CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':base['DEVELOPMENT_TEAM'],'PRODUCT_BUNDLE_IDENTIFIER':'app.vayusetu.ios.activity','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'../Extensions/LiveActivity/Info.plist','GENERATE_INFOPLIST_FILE':'YES','MARKETING_VERSION':base['MARKETING_VERSION'],'CURRENT_PROJECT_VERSION':base['CURRENT_PROJECT_VERSION'],'SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','TARGETED_DEVICE_FAMILY':'1,2','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator'}}))
configs=add('configs',{'isa':'XCConfigurationList','buildConfigurations':cfg,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
target=add('target',{'isa':'PBXNativeTarget','name':'VayuSetuActivity','productName':'VayuSetuActivity','productReference':product,'productType':'com.apple.product-type.app-extension','buildConfigurationList':configs,'buildPhases':[source],'buildRules':[],'dependencies':[]})
if target not in root['targets']:root['targets'].append(target)
proxy=add('proxy',{'isa':'PBXContainerItemProxy','containerPortal':proj['rootObject'],'proxyType':1,'remoteGlobalIDString':target,'remoteInfo':'VayuSetuActivity'})
dep=add('dependency',{'isa':'PBXTargetDependency','target':target,'targetProxy':proxy})
if dep not in full['dependencies']:full['dependencies'].append(dep)
entry=add('embed-build',{'isa':'PBXBuildFile','fileRef':product,'settings':{'ATTRIBUTES':['RemoveHeadersOnCopy']}})
embed=add('embed',{'isa':'PBXCopyFilesBuildPhase','buildActionMask':2147483647,'dstPath':'','dstSubfolderSpec':13,'files':[entry],'name':'Embed Live Activity','runOnlyForDeploymentPostprocessing':0})
if embed not in full['buildPhases']:full['buildPhases'].append(embed)
for ref in [shared,controller,widget]:
 if ref not in o['A00000000000000000000003']['children']:o['A00000000000000000000003']['children'].append(ref)
if product not in o['A00000000000000000000004']['children']:o['A00000000000000000000004']['children'].append(product)
def encode(x):
 if isinstance(x,dict):return '{\n'+''.join(json.dumps(str(k))+' = '+encode(v)+';\n' for k,v in x.items())+'}'
 if isinstance(x,list):return '('+','.join(encode(v) for v in x)+')'
 if isinstance(x,int):return str(x)
 return json.dumps(str(x))
path.write_text('// !$*UTF8*$!\n'+encode(proj)+'\n')
print('Live Activity target added; foreground-only restart.')
