#!/usr/bin/env python3
"""Simulator-only preservation workflow using the app's real accessibility, input and audio adapters."""
import json,os,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/performance-analysis'))
import android_ui as ui
sys.path.insert(0,str(ROOT/'tools/audio'))
from analyze_capture import read_wav

def main():
 serial=sys.argv[1];assert serial.startswith('emulator-'),'This workflow is simulator-only.'
 out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
 d=ui.Device(serial);d.install(str(ROOT/'temple_os_kotlin/app/build/outputs/apk/debug/app-debug.apk'))
 report={'serial':serial,'android':d.shell('getprop ro.build.version.release').strip(),'api':d.shell('getprop ro.build.version.sdk').strip(),'steps':[]}
 def step(name,**data):
  report['steps'].append(dict(name=name,**data));(out/'report.json').write_text(json.dumps(report,indent=1));print(name,data,flush=True)
 def shot(name):d.shot(str(out/(name+'.png')))
 def tap_program(name):
  for _ in range(20):
   if d.find(name,timeout=.1):return d.tap(name)
   d.tap('Scroll menu down')
  raise RuntimeError('program not visible: '+name)
 def close_program():
  ns=d.nodes();label=next(n['label'] for n in ns if n['label'].startswith('Close WaterFowl'));d.tap(label)
 for engine in ['terry','native']:
  d.rotate(False)
  d.launch(extras='--ez nosession true --ez perflog true --ez soundcapture true --es engine '+engine)
  d.tap('MENU');d.tap('Games...');shot('games-'+engine+'-portrait')
  assert d.find('Original menu')
  d.rotate(True);shot('games-'+engine+'-landscape');d.rotate(False)
  d.tap('More programs');tap_program('WaterFowl')
  assert d.find('Window menu: WaterFowl',exact=False,timeout=30)
  time.sleep(4);shot('waterfowl-'+engine+'-portrait')
  if engine=='native':assert any('Pure Kotlin' in n['label'] for n in d.nodes())
  d.rotate(True);time.sleep(2);shot('waterfowl-'+engine+'-landscape')
  d.key('KEYCODE_HOME');time.sleep(2);d.shell('am start -W -n '+ui.ACT);time.sleep(2)
  assert d.find('Window menu: WaterFowl',exact=False)
  d.rotate(False)
  ime=d.shell('dumpsys input_method')
  assert 'mInputShown=true' not in ime
  d.tap('Space');time.sleep(2);shot('waterfowl-'+engine+'-ended')
  assert any('ended' in n['label'].lower() for n in d.nodes()),'program did not exit on character'
  close_program();assert d.find('More programs')
  tap_program('WaterFowl');assert d.find('Window menu: WaterFowl',exact=False,timeout=30);time.sleep(3)
  shot('waterfowl-'+engine+'-reopened');close_program()
  d.key('KEYCODE_HOME');time.sleep(3)
  r=subprocess.run([ui.ADB,'-s',serial,'exec-out','cat','/sdcard/Android/data/'+ui.PKG+'/files/sound-capture-all.wav'],capture_output=True,check=True)
  wav=out/('waterfowl-'+engine+'.wav');wav.write_bytes(r.stdout)
  samples,rate=read_wav(str(wav));assert max(map(abs,samples))>.05,'mixer capture is silent'
  logs=d.adb('logcat','-d','-v','time',check=False)
  (out/(engine+'-logcat.txt')).write_text('\n'.join(l for l in logs.splitlines() if 'TempleOSMobile' in l or 'AndroidRuntime' in l))
  assert 'FATAL EXCEPTION' not in '\n'.join(l for l in logs.splitlines() if 'templeosmobile' in l.lower())
  step('WaterFowl '+engine,portrait=True,landscape=True,lifecycle=True,customKeyboard=True,exit=True,reopen=True,audioBytes=len(r.stdout),audioSampleRate=rate)
 # Real app resize using emulator display overrides; no physical device configuration is touched.
 d.launch(extras='--ez nosession true --es engine terry');d.tap('MENU');d.tap('Games...')
 try:
  d.shell('wm size 2560x1600');d.shell('wm density 320');time.sleep(3);shot('games-tablet-resize');step('tablet viewport',size_override=d.shell('wm size').strip())
  d.shell('wm size 1768x2208');d.shell('wm density 420');time.sleep(3);shot('games-fold-size-resize');step('fold-sized viewport',size_override=d.shell('wm size').strip(),note='resize only; no hinge/posture sensor simulated')
 finally:d.shell('wm size reset');d.shell('wm density reset');d.rotate(False)
 step('complete')
if __name__=='__main__':main()
