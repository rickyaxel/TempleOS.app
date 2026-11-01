#!/usr/bin/env python3
"""Menu UI checks on an emulator, or an explicitly authorized hardware bench app."""
import json
import hashlib
import re
import sys
import time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/performance-analysis'))
import android_ui as ui
from android_target import configure


def main():
    args,d,out,apk=configure(__doc__)
    serial=args.serial;physical=args.physical
    report={'serial':serial,'physicalDeviceTests':int(physical),'package':ui.PKG,'steps':[]}
    def record(name,**extra):
        report['steps'].append(dict(name=name,**extra));(out/'report.json').write_text(json.dumps(report,indent=1)+'\n');print(name,extra,flush=True)
    def shot(name):d.shot(str(out/(name+'.png')))
    def tap_node(node,settle=.8):
        x0,y0,x1,y1=node['bounds'];d.tap_xy((x0+x1)//2,(y0+y1)//2);time.sleep(settle)
    def choose(label):
        for _ in range(30):
            nodes=d.nodes()
            node=next((n for n in nodes if n['label']==label),None)
            if node:tap_node(node);return
            scroll=next((n for n in nodes if n['label']=='Scroll menu down'),None)
            if not scroll:break
            tap_node(scroll,.1)
        raise AssertionError('Not visible: '+label)
    def menu():
        if not d.find('Games...',timeout=.1):d.tap('MENU')
    def close(title):
        # Back from an original submenu restores its parent menu first.
        for _ in range(4):
            node=next((n for n in d.nodes() if n['label'].startswith('Close '+title)),None)
            if node:tap_node(node);return
            d.key('KEYCODE_BACK');time.sleep(.2)
        raise AssertionError('No close control after dismissing nested menus: '+title)
    def no_ime():
        dump=d.shell('dumpsys input_method')
        assert 'mInputShown=true' not in dump
    def memory(name):
        dump=d.shell('dumpsys meminfo '+ui.PKG);(out/(name+'-meminfo.txt')).write_text(dump)
        return next((line.strip() for line in dump.splitlines() if 'TOTAL PSS:' in line),'see meminfo artifact')
    saved_size=d.shell('wm size');saved_density=d.shell('wm density')
    saved_auto=d.shell('settings get system accelerometer_rotation').strip()
    saved_rotation=d.shell('settings get system user_rotation').strip()
    report['apkSHA256']=hashlib.sha256(apk.read_bytes()).hexdigest()
    d.install(str(apk))
    if not physical:d.logcat_clear()
    report.update(android=d.shell('getprop ro.build.version.release').strip(),api=d.shell('getprop ro.build.version.sdk').strip())
    try:
        for engine in ['terry','native']:
            if not physical:d.rotate(False)
            d.launch(clear=not physical and engine=='terry',extras='--ez nosession true --ez perflog true --ez soundcapture true --es engine '+engine)
            expected=['TempleOS.app','Tap MENU to begin.','TempleOS by Terry A. Davis','Mobile adaptation by Ricky Axel']
            labels=[n['label'] for n in d.nodes()]
            assert all(line in labels for line in expected),labels
            shot('intro-'+engine+'-portrait');d.rotate(True)
            assert all(d.find(line,timeout=.1) for line in expected);shot('intro-'+engine+'-landscape');d.rotate(False)
            menu();shot('main-menu-'+engine);choose('Games...')
            seen=set();categories={'Fun Games','Unfun Games','Code Scraps','Nongames'}
            for i in range(6):
                seen.update(n['label'] for n in d.nodes() if n['label'] in categories)
                shot('games-'+engine+'-'+str(i));d.tap('Scroll menu down',settle=.1)
            assert seen==categories,seen
            for _ in range(6):d.tap('Scroll menu up',settle=.1)
            d.tap('More programs');choose('WaterFowl')
            assert d.find('Window menu: WaterFowl',exact=False,timeout=30)
            time.sleep(2);shot('waterfowl-'+engine+'-animated')
            if engine=='native':assert any('Pure Kotlin' in n['label'] for n in d.nodes())
            d.key('KEYCODE_HOME');time.sleep(.5);d.shell('am start -W -n '+ui.ACT);time.sleep(.5)
            no_ime();d.tap('Space');time.sleep(.5)
            assert any('(ended)' in n['label'] for n in d.nodes())
            close('WaterFowl');assert d.find('More programs')
            record('intro/gallery/WaterFowl '+engine,exactIntro=True,categories=sorted(seen),lifecycle=True,exit=True,returnToGallery=True)
            menu();choose('Demos...');shot('demo-index-'+engine);choose('Non-Game');choose('DateTime')
            run='RUN IN '+('Pure Kotlin' if engine=='native' else 'Pure Terry')
            choose(run);assert d.find('Close DateTime',exact=False,timeout=30);time.sleep(1)
            shot('datetime-'+engine);close('DateTime');assert d.find('Edit source')
            d.tap('Back');assert d.find('Non-Game',timeout=.1)
            choose('DskRaw, unavailable');assert d.find('Edit source')
            assert not any(n['label'].startswith('RUN IN') for n in d.nodes())
            d.tap('Edit source');assert d.find('Window menu: DskRaw.HC',exact=False)
            shot('source-only-'+engine);close('DskRaw.HC');assert d.find('Edit source')
            record('program groups/source inspection '+engine,realDateTimeRun=True,unsupportedHasNoRun=True,sourceReturn=True)
            menu();choose('Demos...');choose('TempleOS Specific');choose('MenuBttn');choose(run)
            assert d.find('Snd On',timeout=30);shot('popup-'+engine)
            d.tap('Snd On');d.tap('Set Freq');assert d.find('400 Hz');d.tap('400 Hz');d.tap('Snd Off');d.tap('Done')
            time.sleep(.5);assert any('(ended)' in n['label'] for n in d.nodes());close('MenuBttn')
            no_ime();record('nested source popup '+engine,buttons=True,frequencyChooser=True,cancelAndReturn=True)
            menu();choose('Applications');shot('applications-'+engine);assert d.find('Budget')
            menu();choose('HolyC Editor');d.tap('Window menu: Untitled.HC',exact=False);choose('Program')
            assert d.find('Include');assert d.find('AdamInclude, unavailable')
            shot('editor-context-'+engine);no_ime();d.key('KEYCODE_BACK');close('Untitled.HC')
            menu();choose('Programs');choose('Original menus');choose('Pull-down menus');choose('EdPullDown  [Doc/EdPullDown.DD]')
            shot('menu-reference-'+engine);assert not any(n['label'].startswith('RUN IN') for n in d.nodes())
            record('contextual menu reconstruction '+engine,sourceEventGroups=True,unsupportedAdamInclude=True,referenceDoesNotDispatchOutsideContext=True)
            totals=[]
            for i in range(args.cycles):
                menu();choose('Games...');d.tap('More programs');choose('WaterFowl');assert d.find('Program picture: WaterFowl',exact=False,timeout=30)
                time.sleep(.5);d.tap('Space');assert any('(ended)' in n['label'] for n in d.nodes());close('WaterFowl');assert d.find('More programs')
                totals.append(memory('stress-'+engine+'-'+str(i)))
            record(('five' if args.cycles==5 else str(args.cycles))+' launch/exit cycles '+engine,totalPss=totals)
            if physical:
                pid=d.shell('pidof '+ui.PKG).strip()
                (out/('app-logcat-'+engine+'.txt')).write_text(d.adb('logcat','-d','--pid='+pid,'-v','time',check=False))
        # Real emulator viewport changes, explicitly not a posture/hinge test.
        for name,size,density in ([] if physical else [('tablet','2560x1600','320'),('fold-size','1768x2208','420')]):
            d.shell('wm size '+size);d.shell('wm density '+density);time.sleep(1)
            d.launch(extras='--ez nosession true');shot('intro-'+name);menu();choose('Games...');shot('games-'+name)
            no_ime();record(name+' viewport',size=size,density=density,hingePostureSimulated=False)
        (out/'gfxinfo.txt').write_text(d.shell('dumpsys gfxinfo '+ui.PKG+' framestats'))
        if not physical:
            logs=d.adb('logcat','-d','-v','time',check=False)
            (out/'app-logcat.txt').write_text('\n'.join(line for line in logs.splitlines() if 'TempleOSMobile' in line or 'AndroidRuntime' in line))
        record('complete')
    except Exception as e:
        shot('failure');record('failure',error=str(e));raise
    finally:
        if physical:
            report['globalDisplaySettingsUnchanged']=(saved_size==d.shell('wm size') and saved_density==d.shell('wm density') and
                saved_auto==d.shell('settings get system accelerometer_rotation').strip() and saved_rotation==d.shell('settings get system user_rotation').strip())
            d.rotate(False)
            (out/'report.json').write_text(json.dumps(report,indent=1)+'\n')
            assert report['globalDisplaySettingsUnchanged']
        else:
            for command,saved in [('size',saved_size),('density',saved_density)]:
                match=re.search(r'Override (?:size|density):\s*(\S+)',saved)
                d.shell('wm '+command+' '+(match[1] if match else 'reset'))
            d.shell('settings put system accelerometer_rotation '+saved_auto)
            d.shell('settings put system user_rotation '+saved_rotation)


if __name__=='__main__':main()
