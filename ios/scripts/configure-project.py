from pathlib import Path
import subprocess, json, hashlib, copy
path=Path('VayuSetu.xcodeproj/project.pbxproj')
p=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
o=p['objects']; root=o[p['rootObject']]
def ident(label): return hashlib.sha1(('vayusetu-'+label).encode()).hexdigest()[:24].upper()
def add(label,data): key=ident(label);o[key]=data;return key
def ref(label,path,kind): return add('ref-'+label,{'isa':'PBXFileReference','lastKnownFileType':kind,'path':path,'sourceTree':'SOURCE_ROOT'})
def build(label,file): return add('build-'+label,{'isa':'PBXBuildFile','fileRef':file})
app=o['A00000000000000000000002']; sources=o['A00000000000000000000005']; group=o['A00000000000000000000003']
for name in ['Secrets.swift','TunnelController.swift','RoutePolicy.swift','NetworkDiagnostics.swift','Backup.swift','FeatureViews.swift','DNSOverTLS.swift','DesignSystem.swift','ProfileViews.swift','DNSViews.swift','CheckViews.swift','HomeSettingsViews.swift','ConnectionVerification.swift','VerificationViews.swift','FilteringDiagnostics.swift','FilteringViews.swift','PublicIPProbe.swift','IPDiscoveryViews.swift','PrivacyFeatures.swift','PrivacyFeatureViews.swift','ArchitectureViews.swift','FilteringArchitectureViews.swift']:
    f=ref(name,'Sources/'+name,'sourcecode.swift'); b=build(name,f)
    if f not in group['children']:group['children'].append(f)
    if b not in sources['files']:sources['files'].append(b)
notices=ref('notices','Configuration/ThirdPartyNotices.txt','text'); nb=build('notices',notices)
if nb not in o['A00000000000000000000007']['files']:o['A00000000000000000000007']['files'].append(nb)
privacy=ref('privacy','Configuration/PrivacyInfo.xcprivacy','text.xml'); pb=build('privacy',privacy)
if pb not in o['A00000000000000000000007']['files']: o['A00000000000000000000007']['files'].append(pb)
team=o['A00000000000000000000014']['buildSettings'].get('DEVELOPMENT_TEAM','')
for c in ['A00000000000000000000014','A00000000000000000000015']:
    o[c]['buildSettings'].update({'MARKETING_VERSION':'0.11.2','CURRENT_PROJECT_VERSION':'18','CODE_SIGN_ENTITLEMENTS':'Configuration/Preview.entitlements','INFOPLIST_KEY_VayuAppKeychainGroup':'$(AppIdentifierPrefix)app.vayusetu.ios.preview'})
full_configs=[]
for base in ['A00000000000000000000014','A00000000000000000000015']:
    c=copy.deepcopy(o[base]);c['buildSettings'].update({'PRODUCT_BUNDLE_IDENTIFIER':'app.vayusetu.ios','INFOPLIST_KEY_CFBundleName':'VayuSetu','INFOPLIST_KEY_CFBundleDisplayName':'VayuSetu','INFOPLIST_KEY_VayuKeychainGroup':'$(AppIdentifierPrefix)app.vayusetu.ios.shared','INFOPLIST_KEY_VayuAppKeychainGroup':'$(AppIdentifierPrefix)app.vayusetu.ios','CODE_SIGN_ENTITLEMENTS':'Configuration/App.entitlements','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) VPN_ENABLED'+(' DEBUG' if c['name']=='Debug' else '')})
    full_configs.append(add('full-'+c['name'],c))
full_list=add('full-configs',{'isa':'XCConfigurationList','buildConfigurations':full_configs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
full_product=add('full-product',{'isa':'PBXFileReference','explicitFileType':'wrapper.application','path':'VayuSetuVPN.app','sourceTree':'BUILT_PRODUCTS_DIR'})
ext_product=add('ext-product',{'isa':'PBXFileReference','explicitFileType':'wrapper.app-extension','path':'VayuSetuTunnel.appex','sourceTree':'BUILT_PRODUCTS_DIR'})
products=o['A00000000000000000000004']['children']
for i in [full_product,ext_product]:
    if i not in products: products.append(i)
ext_files=[]
paths=[Path('Tunnel/PacketTunnelProvider.swift'),Path('Tunnel/WireGuardConfigPolicy.swift'),Path('Tunnel/DNSOnlyRuntime.swift'),Path('Sources/Core.swift'),Path('Sources/DNSOverTLS.swift'),Path('Sources/Secrets.swift'),Path('Sources/RoutePolicy.swift')]+sorted(Path('Vendor/wireguard-apple/Sources/WireGuardKit').glob('*.swift'))+sorted(Path('Vendor/wireguard-apple/Sources/WireGuardKitC').glob('*.c'))+[Path('Vendor/wireguard-apple/Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift'),Path('Vendor/wireguard-apple/Sources/Shared/Model/String+ArrayConversion.swift')]
ext_group=[]
for file in paths:
    f=ref('ext-'+str(file),str(file),'sourcecode.c.c' if file.suffix=='.c' else 'sourcecode.swift')
    ext_files.append(build('ext-'+str(file),f));ext_group.append(f)
g=add('tunnel-group',{'isa':'PBXGroup','name':'Tunnel + WireGuard','children':ext_group,'sourceTree':'<group>'})
if g not in group['children']:group['children'].append(g)
phases=[]
phases.append(add('ext-go',{'isa':'PBXShellScriptBuildPhase','buildActionMask':2147483647,'files':[],'inputPaths':[],'outputPaths':['$(CONFIGURATION_BUILD_DIR)/libwg-go.a'],'shellPath':'/bin/bash','shellScript':'bash "${SRCROOT}/scripts/wireguard-go.sh"','runOnlyForDeploymentPostprocessing':0,'alwaysOutOfDate':1,'name':'Build WireGuard backend'}))
phases.append(add('ext-sources',{'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':ext_files,'runOnlyForDeploymentPostprocessing':0}))
phases.append(add('ext-frameworks',{'isa':'PBXFrameworksBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0}))
phases.append(add('ext-resources',{'isa':'PBXResourcesBuildPhase','buildActionMask':2147483647,'files':[pb,nb],'runOnlyForDeploymentPostprocessing':0}))
ext_configs=[]
for name in ['Debug','Release']:
    settings={'CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':team,'CODE_SIGN_ENTITLEMENTS':'Configuration/VPN.entitlements','PRODUCT_BUNDLE_IDENTIFIER':'app.vayusetu.ios.tunnel','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Tunnel/Info.plist','GENERATE_INFOPLIST_FILE':'YES','MARKETING_VERSION':'0.11.2','CURRENT_PROJECT_VERSION':'18','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','TARGETED_DEVICE_FAMILY':'1','SWIFT_VERSION':'5.0','SWIFT_OBJC_BRIDGING_HEADER':'Tunnel/Bridge.h','HEADER_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/Vendor/wireguard-apple/Sources/WireGuardKitGo','$(SRCROOT)/Vendor/wireguard-apple/Sources/WireGuardKitC'],'LIBRARY_SEARCH_PATHS':['$(inherited)','$(BUILT_PRODUCTS_DIR)'],'OTHER_LDFLAGS':['$(inherited)','-lwg-go','-lresolv'],'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','ENABLE_USER_SCRIPT_SANDBOXING':'NO'}
    ext_configs.append(add('ext-'+name,{'isa':'XCBuildConfiguration','name':name,'buildSettings':settings}))
ext_list=add('ext-configs',{'isa':'XCConfigurationList','buildConfigurations':ext_configs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
ext_id=add('extension',{'isa':'PBXNativeTarget','name':'VayuSetuTunnel','productName':'VayuSetuTunnel','productReference':ext_product,'productType':'com.apple.product-type.app-extension','buildConfigurationList':ext_list,'buildPhases':phases,'buildRules':[],'dependencies':[]})
proxy=add('ext-proxy',{'isa':'PBXContainerItemProxy','containerPortal':p['rootObject'],'proxyType':1,'remoteGlobalIDString':ext_id,'remoteInfo':'VayuSetuTunnel'})
dep=add('ext-dependency',{'isa':'PBXTargetDependency','target':ext_id,'targetProxy':proxy})
embedbuild=add('ext-embed-build',{'isa':'PBXBuildFile','fileRef':ext_product,'settings':{'ATTRIBUTES':['RemoveHeadersOnCopy']}})
embed=add('ext-embed',{'isa':'PBXCopyFilesBuildPhase','buildActionMask':2147483647,'dstPath':'','dstSubfolderSpec':13,'files':[embedbuild],'name':'Embed App Extensions','runOnlyForDeploymentPostprocessing':0})
full_phases=[]
for i in ['A00000000000000000000005','A00000000000000000000006','A00000000000000000000007']:
    full_phases.append(add('full-phase-'+i,copy.deepcopy(o[i])))
full_phases.append(embed)
full_id=add('full-target',{'isa':'PBXNativeTarget','name':'VayuSetuVPN','productName':'VayuSetuVPN','productReference':full_product,'productType':'com.apple.product-type.application','buildConfigurationList':full_list,'buildPhases':full_phases,'buildRules':[],'dependencies':[dep]})
for i in [full_id,ext_id]:
    if i not in root['targets']:root['targets'].append(i)
    root['attributes']['TargetAttributes'][i]={'CreatedOnToolsVersion':'27.0','SystemCapabilities':{'com.apple.NetworkExtensions.iOS':{'enabled':1},'com.apple.Keychain':{'enabled':1}}}
# Shared Swift package: identical domain/configuration/diagnostic models across platforms.
oldRuntimeRef=ident('ref-Runtime.swift'); oldRuntimeBuild=ident('build-Runtime.swift')
for obj in o.values():
    for field in ['files','children']:
        if field in obj: obj[field]=[v for v in obj[field] if v not in [oldRuntimeRef,oldRuntimeBuild]]
o.pop(oldRuntimeRef,None);o.pop(oldRuntimeBuild,None)
pkg=add('core-package',{'isa':'XCLocalSwiftPackageReference','relativePath':'../Packages/VayuSetuCore'})
root['packageReferences']=[pkg]
for target,phase,label in [(app,o['A00000000000000000000006'],'preview'),(o[full_id],o[full_phases[1]],'vpn')]:
    product=add('core-product-'+label,{'isa':'XCSwiftPackageProductDependency','package':pkg,'productName':'VayuSetuCore'})
    target['packageProductDependencies']=[product]
    entry=add('core-link-'+label,{'isa':'PBXBuildFile','productRef':product})
    phase['files']=[v for v in phase['files'] if 'productRef' not in o.get(v,{})]
    phase['files'].append(entry)
# On-device UI regression target: does not require Network Extension signing.
ui_file=ref('ui-tests','UITests/LaunchTests.swift','sourcecode.swift')
if ui_file not in group['children']: group['children'].append(ui_file)
ui_sources=add('ui-sources',{'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':[build('ui-tests',ui_file)],'runOnlyForDeploymentPostprocessing':0})
ui_frameworks=add('ui-frameworks',{'isa':'PBXFrameworksBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0})
ui_product=add('ui-product',{'isa':'PBXFileReference','explicitFileType':'wrapper.cfbundle','path':'VayuSetuUITests.xctest','sourceTree':'BUILT_PRODUCTS_DIR'})
if ui_product not in products: products.append(ui_product)
ui_configs=[]
for name in ['Debug','Release']:
    ui_configs.append(add('ui-config-'+name,{'isa':'XCBuildConfiguration','name':name,'buildSettings':{'CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':team,'PRODUCT_BUNDLE_IDENTIFIER':'app.vayusetu.ios.uitests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TEST_TARGET_NAME':'VayuSetuVPN','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks']}}))
ui_list=add('ui-configs',{'isa':'XCConfigurationList','buildConfigurations':ui_configs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
ui_id=add('ui-target',{'isa':'PBXNativeTarget','name':'VayuSetuUITests','productName':'VayuSetuUITests','productReference':ui_product,'productType':'com.apple.product-type.bundle.ui-testing','buildConfigurationList':ui_list,'buildPhases':[ui_sources,ui_frameworks],'buildRules':[],'dependencies':[]})
if ui_id not in root['targets']:root['targets'].append(ui_id)
root['attributes']['TargetAttributes'][ui_id]={'CreatedOnToolsVersion':'27.0','TestTargetID':full_id}
# Serialize OpenStep without touching the user's Xcode account/team or workspace state.
def encode(x):
    if isinstance(x,dict):return '{\n'+''.join(json.dumps(str(k))+ ' = '+encode(v)+';\n' for k,v in x.items())+'}'
    if isinstance(x,list):return '('+','.join(encode(v) for v in x)+')'
    if isinstance(x,int):return str(x)
    return json.dumps(str(x))
path.write_text('// !$*UTF8*$!\n'+encode(p)+'\n')
scheme=Path('VayuSetu.xcodeproj/xcshareddata/xcschemes/VayuSetu.xcscheme').read_text()
scheme=scheme.replace('A00000000000000000000002',full_id).replace('BuildableName="VayuSetu.app"','BuildableName="VayuSetuVPN.app"').replace('BlueprintName="VayuSetu"','BlueprintName="VayuSetuVPN"')
Path('VayuSetu.xcodeproj/xcshareddata/xcschemes/VayuSetuVPN.xcscheme').write_text(scheme)
print('Configured full VPN target and preserved preview signing team.')

ui_scheme=Path('VayuSetu.xcodeproj/xcshareddata/xcschemes/VayuSetu.xcscheme').read_text()
ui_ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_id}" BuildableName="VayuSetuUITests.xctest" BlueprintName="VayuSetuUITests" ReferencedContainer="container:VayuSetu.xcodeproj"/>'
ui_scheme=ui_scheme.replace('</BuildActionEntries>', '<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">'+ui_ref+'</BuildActionEntry></BuildActionEntries>')
ui_scheme=ui_scheme.replace('shouldUseLaunchSchemeArgsEnv="YES"/>','shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+ui_ref+'</TestableReference></Testables></TestAction>',1)
Path('VayuSetu.xcodeproj/xcshareddata/xcschemes/VayuSetuUI.xcscheme').write_text(ui_scheme)

subprocess.run(['python3', 'Scripts/configure-privacy.py'], check=True)

subprocess.run(['python3','Scripts/configure-activity.py'],check=True)

ui_path=Path('VayuSetu.xcodeproj/xcshareddata/xcschemes/VayuSetuUI.xcscheme')
ui_path.write_text(ui_path.read_text().replace('A00000000000000000000002',full_id).replace('BuildableName="VayuSetu.app"','BuildableName="VayuSetuVPN.app"').replace('BlueprintName="VayuSetu"','BlueprintName="VayuSetuVPN"'))
