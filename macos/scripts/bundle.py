import plistlib
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
app=root/'dist/VayuSetu.app'
info={'CFBundleName':'VayuSetu','CFBundleDisplayName':'VayuSetu','CFBundleIdentifier':'app.vayusetu.macos.preview','CFBundleExecutable':'VayuSetu','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'14','CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'VayuSetu by R3dby'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
iconset=root/'build/AppIcon.iconset';iconset.mkdir(exist_ok=True)
source=root.parent/'Design/AppIcons/ArtisticBridge/VayuSetu-macOS-1024.png'
for size in [16,32,128,256,512]:
 for multiplier in [1,2]:
  suffix='@2x' if multiplier==2 else ''
  subprocess.run(['sips','-z',str(size*multiplier),str(size*multiplier),str(source),'--out',str(iconset/f'icon_{size}x{size}{suffix}.png')],check=True,stdout=subprocess.DEVNULL)
