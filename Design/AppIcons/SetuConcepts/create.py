from pathlib import Path
import json
root=Path(__file__).resolve().parent
head='<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
positions=[(260,610,-32),(386,505,-18),(512,465,0),(638,505,18),(764,610,32)]
def artwork(mode):
    tinted=mode=='Tinted';light=mode=='Light'
    bg='' if tinted else '<rect width="1024" height="1024" fill="url(#background)"/>'
    top,bottom=('#F9FAFB','#E9F2F4') if light else (('#0B0D10','#0B1C22') if mode=='Dark' else ('#0B0D10','#0E3A44'))
    defs=f'<linearGradient id="background" x2="0" y2="1"><stop stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>'
    stones=[]
    for i,(x,y,angle) in enumerate(positions):
        if tinted:
            v=160+i*23;color='#'+f'{v:02x}'*3
            fill=color; edge='white';shine=''
        else:
            opacity=.56+i*.075 if not light else .82+i*.03
            defs+=f'<linearGradient id="stone{i}" x1=".2" y1="0" x2=".8" y2="1"><stop stop-color="#B5F2F6" stop-opacity="{opacity}"/><stop offset=".46" stop-color="#2DB6C9" stop-opacity="{opacity}"/><stop offset="1" stop-color="#14788B" stop-opacity=".85"/></linearGradient>'
            fill=f'url(#stone{i})';edge='#BAF5F7';shine='<path d="M-27 -32C-22 -48 1 -53 20 -43" fill="none" stroke="white" stroke-opacity=".48" stroke-width="5" stroke-linecap="round"/>'
        stones.append(f'<g id="pebble-{i+1}" transform="translate({x} {y}) rotate({angle})"><ellipse rx="49" ry="64" fill="{fill}" stroke="{edge}" stroke-opacity=".58" stroke-width="3"/>{shine}</g>')
    windcolor='white' if tinted else '#2DB6C9'
    wind=f'<g id="wind" fill="none" stroke="{windcolor}" stroke-opacity=".48" stroke-width="14" stroke-linecap="round"><path d="M155 638C186 637 201 624 218 602"/><path d="M169 674C194 674 214 660 229 645"/></g>'
    glow='' if tinted else '<defs><radialGradient id="glow"><stop stop-color="#2DB6C9" stop-opacity=".24"/><stop offset="1" stop-color="#2DB6C9" stop-opacity="0"/></radialGradient></defs><ellipse id="accent" cx="768" cy="666" rx="91" ry="44" fill="url(#glow)"/>'
    return head+'<defs>'+defs+'</defs>'+bg+glow+wind+''.join(stones)+'</svg>'
for mode in ['Default','Dark','Light','Tinted']:(root/f'Setu-Stones-{mode}.svg').write_text(artwork(mode))
# Editable neutral silhouettes for real Icon Composer materials. Avoid baking
# the preview's simulated edge lighting into these production source layers.
(root/'layers/Background.svg').write_text(head+'<defs><linearGradient id="b" x2="0" y2="1"><stop stop-color="#0B0D10"/><stop offset="1" stop-color="#0E3A44"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#b)"/></svg>')
for i,(x,y,angle) in enumerate(positions):
    (root/f'layers/Pebble-{i+1}.svg').write_text(head+f'<ellipse cx="{x}" cy="{y}" rx="49" ry="64" transform="rotate({angle} {x} {y})" fill="#2DB6C9"/></svg>')
(root/'layers/Wind.svg').write_text(head+'<g fill="none" stroke="#2DB6C9" stroke-width="14" stroke-linecap="round"><path d="M155 638C186 637 201 624 218 602"/><path d="M169 674C194 674 214 660 229 645"/></g></svg>')
(root/'layers/Accent.svg').write_text(head+'<ellipse cx="768" cy="666" rx="68" ry="25" fill="#2DB6C9" fill-opacity=".2"/></svg>')
bg='<defs><linearGradient id="b" x2="0" y2="1"><stop stop-color="#0B0D10"/><stop offset="1" stop-color="#0E3A44"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#b)"/>'
f=json.loads((root/'vayu-glyph.json').read_text())
(root/'Vayu-Letter.svg').write_text(head+bg+f'<g fill="#2DB6C9"><path transform="translate({f["tx"]} {f["ty"]}) scale({f["scale"]} {-f["scale"]})" d="{f["path"]}"/></g><path d="M250 370H774" stroke="#2DB6C9" stroke-width="32" stroke-linecap="round"/></svg>')
(root/'Two-Glasses.svg').write_text(head+bg+'<defs><linearGradient id="g" x2="0" y2="1"><stop stop-color="#99E9F1" stop-opacity=".8"/><stop offset="1" stop-color="#2DB6C9" stop-opacity=".22"/></linearGradient></defs><g fill="url(#g)" stroke="#ACF1F6" stroke-opacity=".7" stroke-width="4"><path d="M240 610C240 360 530 340 620 565C474 680 335 680 240 610Z"/><path d="M784 610C784 360 494 340 404 565C550 680 689 680 784 610Z"/></g><path d="M320 575H704" fill="none" stroke="#B6F5F7" stroke-width="22" stroke-linecap="round"/></svg>')
print('Created three editable concepts, four Setu Stones appearances and eight separate layers.')
