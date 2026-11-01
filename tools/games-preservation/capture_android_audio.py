#!/usr/bin/env python3
"""Capture actual AudioTrack samples before a subsequent idle burst overwrites the last-burst WAV."""
import sys,time,subprocess,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools/performance-analysis'));import android_ui as ui
sys.path.insert(0,str(ROOT/'tools/audio'));from analyze_capture import read_wav,segment,pitch
serial=sys.argv[1];assert serial.startswith('emulator-')
out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True);d=ui.Device(serial)
rows=[]
for engine in ['terry','native']:
 d.rotate(False);d.launch(extras='--ez nosession true --ez soundcapture true --es engine '+engine)
 d.tap('MENU');d.tap('Games...');d.tap('More programs');d.tap('WaterFowl');time.sleep(7)
 d.tap('Space');time.sleep(3)
 assert any('ended' in n['label'].lower() for n in d.nodes())
 d.key('KEYCODE_HOME');time.sleep(3)
 r=subprocess.run([ui.ADB,'-s',serial,'exec-out','cat','/sdcard/Android/data/'+ui.PKG+'/files/sound-capture-all.wav'],capture_output=True,check=True)
 p=out/('waterfowl-'+engine+'.wav');p.write_bytes(r.stdout);x,rate=read_wav(str(p));assert max(map(abs,x))>.05
 assert all(v==0 for v in x[-rate//10:]),'sound did not stop on exit'
 rows.append({'engine':engine,'sampleRate':rate,'samples':len(x),'peak':max(map(abs,x)),'bytes':len(r.stdout),'exitSilence':True})
 print(rows[-1],flush=True)
(out/'audio-captures.json').write_text(json.dumps(rows,indent=1)+'\n')
