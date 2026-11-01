#!/usr/bin/env python3
"""Capture both real simulator mixer outputs and resolve the current app container after each install/run.

Usage: capture_ios_audio.py SIMULATOR_UDID
"""
import os,sys,subprocess,json,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];out=ROOT/'docs/games-preservation/evidence/ios-phone'
sys.path.insert(0,str(ROOT/'tools/audio'));from analyze_capture import read_wav
SIM=sys.argv[1]
rows=[]
for mode in ['terry','native']:
 env=os.environ.copy();env['TEST_RUNNER_TEMPLEOS_GAMES_ENGINE']=mode;env['TEST_RUNNER_TEMPLEOS_SHOTS']=str(out)
 result='/tmp/templeos-games-audio-'+mode+'-verified-'+str(time.time_ns())+'.xcresult'
 cmd=['xcodebuild','-project',str(ROOT/'temple_os_swift/App/TempleOSMobile.xcodeproj'),'-scheme','TempleOSMobile','-destination','platform=iOS Simulator,id='+SIM,'-configuration','Debug','-derivedDataPath','/tmp/templeos-games-ios','-resultBundlePath',result,'-parallel-testing-enabled','NO','-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testWaterFowlAudioCapture','test-without-building']
 with (out.parent/('ios-audio-'+mode+'-verified.log')).open('w') as log:subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',SIM,'io.github.templeosmobile','data'],text=True).strip())
 src=container/'Documents/sound-capture.wav';assert src.is_file(),str(src)
 dest=out/('waterfowl-'+mode+'.wav');dest.write_bytes(src.read_bytes())
 meta=container/'Documents/sound-capture.json'
 if meta.exists():(out/('waterfowl-'+mode+'-audio.json')).write_bytes(meta.read_bytes())
 x,rate=read_wav(str(dest));assert max(map(abs,x))>.05
 assert all(v==0 for v in x[-rate//10:]),'sound did not stop on exit'
 rows.append({'engine':mode,'samples':len(x),'sampleRate':rate,'peak':max(map(abs,x)),'bytes':dest.stat().st_size,'exitSilence':True,'resultBundle':result})
 print(rows[-1],flush=True)
(out/'audio-captures.json').write_text(json.dumps(rows,indent=1)+'\n')
