"""Package approved artwork into native iOS assets and all macOS ICNS sizes."""
import json
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[3]
art = root / 'Design/AppIcons'
ios = root / 'ios/Assets.xcassets/AppIcon.appiconset'
mac = root / 'macos/Resources'
iconset = art / 'VayuSetu.iconset'
iconset.mkdir(exist_ok=True)
mac.mkdir(exist_ok=True)
def resize(source, pixels, destination):
    subprocess.run(['sips', '-z', str(pixels), str(pixels), str(source), '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)
images = []
for idiom, points, scales in [('iphone', [20,29,40,60], [2,3]), ('ipad', [20,29,40,76], [1,2]), ('ipad', [83.5], [2])]:
    for point in points:
        for scale in scales:
            name = f'{idiom}-{point}@{scale}x.png'
            resize(art/'VayuSetu-iOS-master.png', int(point*scale), ios/name)
            images.append({'idiom':idiom,'size':f'{point}x{point}','scale':f'{scale}x','filename':name})
resize(art/'VayuSetu-iOS-master.png', 1024, ios/'AppIcon.png')
images.append({'idiom':'ios-marketing','size':'1024x1024','scale':'1x','filename':'AppIcon.png'})
(ios/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}}, indent=2)+'\n')
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        suffix = '@2x' if scale == 2 else ''
        resize(art/'VayuSetu-macOS-master.png', size*scale, iconset/f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(mac/'AppIcon.icns')],check=True)
print('Packaged iOS icon slots and macOS 16–1024 pixel ICNS.')
