#!/usr/bin/env python3
"""Validate shared identities, immutable source provenance, icon bytes, native bindings and reference pixels."""
import hashlib,json,re,struct,zlib
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2];S=ROOT/'shared';D=ROOT/'docs/games-preservation'
def sha(b):return hashlib.sha256(b).hexdigest()
def main():
 c=json.loads((S/'program-manifests/catalog.json').read_text())['programs'];program_count=len(c)
 assert len({p['id'] for p in c})==len(c);assert len({p['path'].lower() for p in c})==len(c)
 native={p['path']:p for p in json.loads((S/'native-translation/manifest.json').read_text())['sources']}
 sw=(ROOT/'temple_os_swift/TempleCore/Sources/PureSwift/Generated/NativeCatalog.swift').read_text()
 kt=(ROOT/'temple_os_kotlin/purekotlin/src/main/kotlin/io/github/templeosmobile/purekotlin/gen/NativeCatalog.kt').read_text()
 for p in c:
  source=S/'bundled-fs'/p['path'][3:];assert source.is_file();assert sha(source.read_bytes())==p['sourceSHA256']
  for dep in p['dependencies']:
   if not (S/'bundled-fs'/dep[3:]).is_file():assert p['status']=='unsupported' and dep in p.get('missingDependencies',[]),dep
  for key in ['nativeSwift','nativeKotlin']:
   if p['executionModes'][key]!='translated':continue
   n=native[p['path']];assert n['status']=='translated';assert p['path'] in sw and p['path'] in kt
   module=n['variants'][0].split(':')[0] if n.get('variants') else n['module'];assert (ROOT/'temple_os_swift/TempleCore/Sources/PureSwift/Generated'/(module+'.swift')).is_file()
   assert (ROOT/'temple_os_kotlin/purekotlin/src/main/kotlin/io/github/templeosmobile/purekotlin/gen'/(module+'.kt')).is_file()
 menu=json.loads((S/'runtime/games-menu/menu.json').read_text());orig=(ROOT/'reference/templeos-iso/PersonalMenu.DD').read_bytes()
 assert menu['sourceSHA256']==sha(orig);assert orig==(S/'bundled-fs/PersonalMenu.DD').read_bytes()
 bins={};at=orig.index(0)+1
 while at+16<=len(orig):
  num,flags,n,use=struct.unpack_from('<IIII',orig,at);at+=16;bins[num]=orig[at:at+n];at+=n
 assert len(menu['entries'])==28;assert [e['sprite'] for e in menu['entries']]==list(range(1,29))
 assert [e['order'] for e in menu['entries']]==list(range(28))
 for e in menu['entries']:
  assert sha(bins[e['sprite']])==e['spriteSHA256']
  b=(S/'runtime'/e['asset']).read_bytes();assert sha(b)==e['assetSHA256']
  magic,w,h=struct.unpack('<4sHH',b[:8]);assert magic==b'TOSI';assert (w,h)==(e['width'],e['height']);assert len(b)==8+w*h
  assert all(p<16 or p==255 for p in b[8:])
  p=next((p for p in c if p['id']==e['programId']),None)
  if p:assert p['path']==e['sourcePath'];assert p['originalMenu']['sprite']==e['sprite']
 animations=[]
 for e in menu['entries']:
  if not e.get('animationAsset'):continue
  data=(S/'runtime'/e['animationAsset']).read_bytes();assert sha(data)==e['animationSHA256']
  magic,w,h,count,reserved,period=struct.unpack_from('<4sHHHHI',data)
  assert magic==b'TOSA' and (w,h)==(e['animationWidth'],e['animationHeight']) and count==630 and period==62832
  offsets=struct.unpack_from('<'+'I'*(count+1),data,16);base=16+4*(count+1)
  assert offsets[0]==0 and offsets[-1]==len(data)-base
  hashes=set()
  for a,b in zip(offsets,offsets[1:]):
   assert a<b
   pixels=zlib.decompress(data[base+a:base+b]);assert len(pixels)==w*h and all(p<16 or p==255 for p in pixels)
   hashes.add(sha(pixels))
  assert len(hashes)>500
  animations.append(dict(icon=e['title'],frames=count,distinctFrames=len(hashes),bytes=len(data),width=w,height=h,periodMs=period,sha256=sha(data)))
 assert len(animations)==6
 # The unmodified reference system's VGA DAC quantizes the 16-bit palette to six-bit channels.
 # QEMU expands those channels with the low bit replicated. Logical assets keep the original indices.
 values=[0,0x0000aa,0x00aa00,0x00aaaa,0xaa0000,0xaa00aa,0xaa5500,0xaaaaaa,0x555555,0x5555ff,0x55ff55,0x55ffff,0xff5555,0xff55ff,0xffff55,0xffffff]
 def dac(c):v=c>>2;return v*4+(3 if v&1 else 0)
 pal=[tuple(dac(c) for c in (v>>16&255,v>>8&255,v&255)) for v in values]
 ref=Image.open(D/'evidence/original-system-menu-top.png').convert('RGB');pixels=[]
 for e in menu['entries'][:8]:
  if e['title']=='Varoom':continue # original is a continuously rotating mesh, exported at identity orientation
  b=(S/'runtime'/e['asset']).read_bytes()[8:]
  x=8+e['documentColumn']*8+len(e['originalLabel'])*8+e['minX'];y=24+e['documentLine']*8+e['minY'];n=0
  for yy in range(e['height']):
   for xx in range(e['width']):
    c=b[yy*e['width']+xx]
    if c==255:continue
    assert ref.getpixel((x+xx,y+yy))==pal[c],(e['title'],xx,yy);n+=1
  pixels.append(dict(icon=e['title'],matchingPixels=n))
 report={'catalogPrograms':program_count,'originalIcons':28,'canonicalIconBytes':sum((S/'runtime'/e['asset']).stat().st_size for e in menu['entries']),'animations':animations,'animationBytes':sum(a['bytes'] for a in animations),'referencePixelMatches':pixels,'referencePixels':sum(p['matchingPixels'] for p in pixels),'notes':['All 28 exports pass provenance/dimensions/palette/hash checks. Seven visible non-mesh icons match the original-system capture pixel for pixel after VGA DAC conversion.','Six original mesh icons also have 630 original-rendered frames over the exact 20π-second rotation cycle, sampled at approximately 10 Hz.']}
 (D/'evidence/asset-validation.json').write_text(json.dumps(report,indent=1)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
