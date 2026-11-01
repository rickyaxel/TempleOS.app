#!/usr/bin/env python3
"""Generated-model View/animation/exit checks, with explicit opt-in for hardware."""
import hashlib
import json
from pathlib import Path
import re
import sys
import time
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/performance-analysis'))
import android_ui as ui
from android_target import configure


def main():
    args,d,out,apk=configure(__doc__)
    serial=args.serial
    d.install(str(apk));rows=[]
    def choose(label):
        for _ in range(20):
            nodes=d.nodes();hit=next((n for n in nodes if n['label']==label),None)
            if hit:
                x0,y0,x1,y1=hit['bounds'];d.tap_xy((x0+x1)//2,(y0+y1)//2);time.sleep(.4);return
            scroll=next((n for n in nodes if n['label']=='Scroll menu down'),None)
            if not scroll:break
            x0,y0,x1,y1=scroll['bounds'];d.tap_xy((x0+x1)//2,(y0+y1)//2)
        raise AssertionError('Missing '+label)
    def escape():
        if not d.find('Escape',timeout=.1):d.tap('Fn',timeout=2)
        d.tap('Escape')
    try:
        if not args.physical:d.rotate(False)
        for engine in ['terry','native']:
            d.launch(extras='--ez nosession true --es engine '+engine)
            choose('MENU');choose('Games...');choose('GrModels');d.tap('Man',timeout=30)
            if not d.find('q',timeout=.1):d.tap('Window menu: GrModels',exact=False);choose('Show keyboard')
            escape()
            for part in ['Shirt','Pants','Skin','Shoes']:
                assert d.find(part,exact=False,timeout=20)
                d.tap('__CYAN',exact=False)
            if not d.find('q',timeout=.1):d.tap('Window menu: GrModels',exact=False);choose('Show keyboard')
            d.tap('n');time.sleep(1)
            node=d.find('Program picture: GrModels',exact=False,timeout=20);assert node
            box=tuple(node['bounds'])
            d.shot(str(out/(engine+'-before.png')));time.sleep(1);d.shot(str(out/(engine+'-after.png')))
            a=Image.open(out/(engine+'-before.png')).convert('RGB').crop(box)
            b=Image.open(out/(engine+'-after.png')).convert('RGB').crop(box)
            changed=sum(x!=y for x,y in zip(a.get_flattened_data(),b.get_flattened_data()))
            assert changed>200,'Generated mesh did not animate: '+str(changed)
            assert not any('(ended)' in n['label'] for n in d.nodes())
            if args.physical:
                d.key('KEYCODE_HOME');time.sleep(.5)
                assert d.foreground_package()!=ui.PKG,'Home did not background the bench app'
                d.shell('am start -W -n '+ui.ACT);time.sleep(1)
                assert d.foreground_package()==ui.PKG,'Bench app did not return to foreground'
                resumed=d.find('Program picture: GrModels',exact=False,timeout=10);assert resumed
                d.shot(str(out/(engine+'-resumed-before.png')));time.sleep(1);d.shot(str(out/(engine+'-resumed-after.png')))
                a=Image.open(out/(engine+'-resumed-before.png')).convert('RGB').crop(tuple(resumed['bounds']))
                b=Image.open(out/(engine+'-resumed-after.png')).convert('RGB').crop(tuple(resumed['bounds']))
                resumed_changed=sum(x!=y for x,y in zip(a.get_flattened_data(),b.get_flattened_data()))
                assert resumed_changed>200,'Generated mesh did not resume: '+str(resumed_changed)
            escape();time.sleep(.5);assert any('(ended)' in n['label'] for n in d.nodes())
            d.tap('Close GrModels',exact=False);assert d.find('More programs')
            assert 'mInputShown=true' not in d.shell('dumpsys input_method')
            rows.append(dict(engine=engine,changedPicturePixels=changed,viewRemainedOpen=True,escapeExited=True,returnedToGames=True,
                foregroundTransitionVerified=args.physical,changedAfterResumePixels=resumed_changed if args.physical else None))
            print(rows[-1],flush=True)
    except Exception:
        d.shot(str(out/'failure.png'));raise
    finally:
        (out/'report.json').write_text(json.dumps(dict(serial=serial,physicalDeviceTests=int(args.physical),package=ui.PKG,apkSHA256=hashlib.sha256(apk.read_bytes()).hexdigest(),runs=rows),indent=2)+'\n')


if __name__=='__main__':main()
