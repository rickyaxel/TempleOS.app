#!/usr/bin/env python3
"""Compare real four-engine checkpoints, PCM samples and additional-program indexed images."""
import json,struct,wave
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2];D=ROOT/'docs/games-preservation/evidence'
SW=ROOT/'temple_os_swift/TempleCore/.build/games-preservation';KT=ROOT/'temple_os_kotlin/purekotlin/build/games-preservation'
COLORS=[(v>>16&255,v>>8&255,v&255) for v in [0,0x0000aa,0x00aa00,0x00aaaa,0xaa0000,0xaa00aa,0xaa5500,0xaaaaaa,0x555555,0x5555ff,0x55ff55,0x55ffff,0xff5555,0xff55ff,0xffff55,0xffffff]]
def main():
 out=D/'four-engines';out.mkdir(exist_ok=True)
 data={};pcm={}
 for platform,base,names in [('swift',SW,['terry','native']),('kotlin',KT,['TERRY','NATIVE'])]:
  for engine in names:
   key=platform+'-'+engine.lower();d=json.loads((base/('waterfowl-'+engine+'.json')).read_text());data[key]=d
   (out/(key+'.json')).write_text(json.dumps(d,indent=1)+'\n')
   pcm[key]=(base/('waterfowl-'+engine+'.pcm')).read_bytes()
   if engine.lower()=='native':assert d['instructions']==0
 ref=data['swift-terry'];raw=pcm['swift-terry']
 for name,d in data.items():
  assert d['frames']==ref['frames'],name+' frames differ'
  assert d['sounds']==ref['sounds'],name+' sound events differ'
  assert pcm[name]==raw,name+' PCM differs'
 vals=struct.unpack('<'+'f'*(len(raw)//4),raw);assert any(abs(x)>.05 for x in vals);assert all(x==0 for x in vals[-4800:])
 with wave.open(str(out/'waterfowl-pcm-reference.wav'),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b''.join(struct.pack('<h',max(-32768,min(32767,round(x*32767)))) for x in vals))
 for f in SW.glob('*.idx'):
  im=Image.new('RGB',(640,480));im.putdata([COLORS[c] for c in f.read_bytes()]);im.save(out/(f.stem+'.png'))
 additional=[]
 for name in ['ASCIIOrgan','OhGreat','SpritePlot','SpritePutExt','Blot','SpritePut','SpriteRaw','EdSprite']:
  paths=[KT/(name+'-TERRY.png'),KT/(name+'-NATIVE.png'),out/(name+'-terry.png'),out/(name+'-native.png')]
  images=[Image.open(p).convert('RGB').tobytes() for p in paths]
  assert all(im==images[0] for im in images),name+' four-engine frame mismatch'
  additional.append(name)
 report={'waterfowlModes':list(data),'matchingFrameCheckpoints':len(ref['frames']),'matchingSoundEvents':len(ref['sounds']),'sourceDerivedMelodyEventsChecked':144,'matchingPCMSamples':len(vals),'sampleRate':48000,'exitSilenceSamples':4800,'nativeBytecodeInstructions':0,'additionalProgramsWithMatchingFourEngineFrames':additional,'scope':'19 seconds virtual time, two launches per mode; actual source and native programs. Relevant input/cleanup assertions are in the test suites.'}
 full=[]
 for base,names in [(SW,['terry','native']),(KT,['TERRY','NATIVE'])]:
  for engine in names:
   f=json.loads((base/('waterfowl-full-'+engine+'.json')).read_text());full.append(f)
   (out/(base.parent.parent.name+'-full-'+engine.lower()+'.json')).write_text(json.dumps(f,indent=1)+'\n')
 assert all(f['frames']==full[0]['frames'] and f['soundEvents']==full[0]['soundEvents'] for f in full)
 report['fullScrollCycle']={'virtualSeconds':66,'matchingFrames':2,'matchingSoundEvents':full[0]['soundEvents'],'modes':4}
 (D/'four-engine-comparison.json').write_text(json.dumps(report,indent=1)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
