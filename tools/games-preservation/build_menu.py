#!/usr/bin/env python3
"""Derive historical metadata and previews from V5.03 DolDoc + canonical runtime rasters.
Run :translator:run --args=extract-menu first. No replacement art is created.
"""
from pathlib import Path
import hashlib,json,re,struct,sys
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[2]; SHARED=ROOT/'shared'
def sha(b): return hashlib.sha256(b).hexdigest()
def build():
 raw=(SHARED/'bundled-fs/PersonalMenu.DD').read_bytes(); text=raw.split(b'\0')[0].decode('latin1')
 assert raw==(ROOT/'reference/templeos-iso/PersonalMenu.DD').read_bytes()
 rasters={x['sprite']:x for x in json.loads((SHARED/'runtime/games-menu/rasters.json').read_text())}
 cat=json.loads((SHARED/'program-manifests/catalog.json').read_text()); bypath={x['path']:x for x in cat['programs']}
 section='';entries=[];group_row=-1;start=0;header_line=0;header_col=0
 for ln,line in enumerate(text.splitlines()):
  m=re.search(r'\$FG,5\$(Fun Games|Unfun Games|Code Scraps|Nongames)',line)
  if m: section=m[1];group_row=-1;header_line=ln;header_col=len(line[:m.start()].expandtabs(8))
  tags=list(re.finditer(r'\$SP\+PU,"([^"]*)",LM="((?:\\.|[^"\\])*)",BI=(\d+)\$',line))
  if not tags:continue
  group_row+=1;col=0;end=0
  for i,m in enumerate(tags):
   col+=len(line[end:m.start()].expandtabs(8));label=m[1];macro=m[2].replace('\\"','"').replace('\\n','\n');num=int(m[3])
   path=re.search(r'#include "::/([^"]+)"',macro)[1];path='C:/'+path.removesuffix('.Z');path+= '' if path.endswith('.HC') else '.HC'
   p=bypath.get(path);pid=p['id'] if p else 'original.jukebox' if num==24 else 'original.'+str(num)
   e=dict(programId=pid,title=label.strip(),originalLabel=label,category=section,order=num-1,row=group_row,column=i,sourcePath=path,launchMacro=macro,documentLine=ln,documentColumn=col,headingLine=header_line,headingColumn=header_col,**rasters[num])
   entries.append(e);col+=len(label);end=m.end()
 assert len(entries)==28
 out=dict(version=1,source='C:/PersonalMenu.DD',sourceVersion='TempleOS V5.03',sourceSHA256=sha(raw),palette='TempleOS standard EGA indices 0..15; 255 transparent',entries=entries)
 dest=SHARED/'runtime/games-menu/menu.json';dest.write_text(json.dumps(out,indent=1)+'\n')
 docs=ROOT/'docs/games-preservation';docs.mkdir(exist_ok=True)
 (docs/'icon-manifest.json').write_text(json.dumps(out,indent=1)+'\n')
 palette=[0x000000,0x0000aa,0x00aa00,0x00aaaa,0xaa0000,0xaa00aa,0xaa5500,0xaaaaaa,0x555555,0x5555ff,0x55ff55,0x55ffff,0xff5555,0xff55ff,0xffff55,0xffffff]
 sheet=Image.new('RGB',(560,7*112),'white')
 font=(SHARED/'runtime/font8x8.bin').read_bytes()
 def glyphs(x,y,s,c):
  for n,ch in enumerate(s.encode('cp437')):
   for yy in range(8):
    for xx in range(8):
     if font[ch*8+yy] & (1<<xx):sheet.putpixel((x+n*8+xx,y+yy),((c>>16)&255,(c>>8)&255,c&255))
 for i,e in enumerate(entries):
  data=(SHARED/'runtime'/e['asset']).read_bytes();magic,w,h=struct.unpack('<4sHH',data[:8]);assert magic==b'TOSI'
  assert (w,h)==(e['width'],e['height']);assert sha(data)==e['assetSHA256']
  pix=data[8:];im=Image.new('RGBA',(w,h));im.putdata([((palette[c]>>16)&255,(palette[c]>>8)&255,palette[c]&255,255) if c!=255 else (0,0,0,0) for c in pix])
  im.save(docs/'evidence'/('icon-%02d.png'%e['sprite']))
  x=(i%5)*112;y=(i//5)*112;label=e['originalLabel'];tx=x+(112-len(label)*8)//2;baseline=y+84
  sheet.paste(im,(tx+len(label)*8+e['minX'],baseline+e['minY']),im);glyphs(tx,baseline,label,0x5555ff)
 sheet.save(docs/'evidence/icons-contact-sheet.png')
 # Exact document-coordinate reference: no mobile layout, original blank lines, anchors and labels.
 first=text[:text.index('Fun Games')].count('\n')
 ref=Image.new('RGB',(640,(len(text.splitlines())-first)*8),'white');sheet_saved=sheet;sheet=ref
 for j,line in enumerate(text.splitlines()[first:]):
  m=re.search(r'\$FG,5\$(Fun Games|Unfun Games|Code Scraps|Nongames)',line)
  if m:glyphs(80,j*8,m[1],0xaa00aa)
 for e in entries:
  data=(SHARED/'runtime'/e['asset']).read_bytes();w=e['width'];h=e['height'];im=Image.new('RGBA',(w,h));im.putdata([((palette[c]>>16)&255,(palette[c]>>8)&255,palette[c]&255,255) if c!=255 else (0,0,0,0) for c in data[8:]])
  x=e['documentColumn']*8;y=(e['documentLine']-first)*8;glyphs(x,y,e['originalLabel'],0x5555ff);sheet.paste(im,(x+len(e['originalLabel'])*8+e['minX'],y+e['minY']),im)
 sheet.save(docs/'evidence/original-menu-source-reconstruction.png')
 print(f'{dest}: {len(entries)} authentic icons, {sum((SHARED/"runtime"/e["asset"]).stat().st_size for e in entries)} bytes')
if __name__=='__main__':build()
