"""Compile local country-range data after downloading these inputs into build/geo:
countries.geojson: https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson
ipv4.csv: https://github.com/sapics/ip-location-db/releases/download/latest/dbip-country-ipv4-num.csv
ipv6.csv: https://github.com/sapics/ip-location-db/releases/download/latest/dbip-country-ipv6-num.csv
DB-IP Lite: CC BY 4.0; Natural Earth: public domain. Attribution ships with the app.
"""
import csv, json, struct
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=root/'build/geo'; target=root/'Resources/Geo'; target.mkdir(parents=True,exist_ok=True)
features=json.loads((source/'countries.geojson').read_text())['features']
centres={}
for f in features:
 p=f['properties']; code=p.get('ISO_A2_EH',p.get('ISO_A2'))
 if code and len(code)==2 and code!='-99':
  centres[code]={'code':code,'name':p['NAME_EN'],'latitude':p['LABEL_Y'],'longitude':p['LABEL_X']}
(target/'Countries.json').write_text(json.dumps(centres,sort_keys=True))
for family in (4,6):
 count=0; last=-1
 with (target/f'IPv{family}.bin').open('wb') as out:
  for start,end,country in csv.reader((source/f'ipv{family}.csv').open()):
   start,end=int(start),int(end)
   assert start>last and end>=start and len(country)==2
   out.write(start.to_bytes(16,'big')+end.to_bytes(16,'big')+country.encode('ascii'))
   last=end;count+=1
 print(f'IPv{family}: {count} ranges')
(target/'Attribution.txt').write_text('IP Geolocation by DB-IP — https://db-ip.com/\nDB-IP Lite country data, CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nSource mirror: https://github.com/sapics/ip-location-db/releases/tag/latest\nCountry label coordinates: Natural Earth (public domain), https://www.naturalearthdata.com/\nCompiled 2026-10-18. Country estimates are approximate, not device or server locations.\n')
