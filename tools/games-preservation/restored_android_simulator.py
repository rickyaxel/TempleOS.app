#!/usr/bin/env python3
"""Actual simulator UI checks for the restored historical entries. Never targets physical devices."""
import json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/performance-analysis'))
import android_ui as ui

def main():
    serial=sys.argv[1];assert serial.startswith('emulator-')
    out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
    d=ui.Device(serial);d.install(str(ROOT/'temple_os_kotlin/app/build/outputs/apk/debug/app-debug.apk'))
    report={'serial':serial,'android':d.shell('getprop ro.build.version.release').strip(),'api':d.shell('getprop ro.build.version.sdk').strip(),'steps':[]}
    def record(name,**fields):
        report['steps'].append(dict(name=name,**fields));(out/'report.json').write_text(json.dumps(report,indent=1)+'\n');print(name,fields,flush=True)
    def shot(name):d.shot(str(out/(name+'.png')))
    def menu_program(title):
        for _ in range(24):
            if d.find(title,timeout=.1):d.tap(title);return
            d.tap('Scroll menu down')
        if d.find('More programs',timeout=.1):d.tap('More programs')
        for _ in range(24):
            if d.find(title,timeout=.1):d.tap(title);return
            d.tap('Scroll menu down')
        raise RuntimeError('Missing catalog entry '+title)
    def menu_item(label):
        for _ in range(64):
            if d.find(label,timeout=.1):d.tap(label);return
            if not d.find('Scroll menu down',timeout=.1):break
            d.tap('Scroll menu down',settle=.2)
        raise RuntimeError('Missing menu item '+label)
    def keyboard(title):
        if not d.find('q',timeout=.1):
            d.tap('Window menu: '+title,exact=False);menu_item('Show keyboard')
        assert d.find('q',timeout=10),'TempleOS keyboard not visible'
        assert 'mInputShown=true' not in d.shell('dumpsys input_method'),'System keyboard opened'
    for engine in ['terry','native']:
        for title in ['JukeBox','Psalmody','Budget','GrModels','ToTheFront','Vocabulary']:
            try:
                d.rotate(False);d.launch(extras='--ez nosession true --ez soundcapture true --es engine '+engine)
                d.tap('MENU');d.tap('Games...');menu_program(title)
                if title=='GrModels':d.tap('Man',timeout=30);time.sleep(1)
                assert d.find('Window menu: '+title,exact=False,timeout=40)
                time.sleep(3)
                if title=='ToTheFront':
                    keyboard(title);d.tap('Enter')
                    for _ in range(2):d.tap('Human',exact=False,timeout=60)
                    d.tap('OKAY',timeout=20);time.sleep(2)
                keyboard(title)
                if engine=='native':assert d.find(title+' · Pure Kotlin',exact=False)
                shot('restored-'+title+'-'+engine+'-portrait')
                if title=='JukeBox':d.tap('Space');time.sleep(3)
                elif title=='Vocabulary':d.tap('1');time.sleep(1)
                elif title=='Psalmody':
                    for c in ['z','a','s']:d.tap(c)
                d.rotate(True);time.sleep(1);shot('restored-'+title+'-'+engine+'-landscape')
                d.key('KEYCODE_HOME');time.sleep(1);d.shell('am start -W -n '+ui.ACT);time.sleep(1);d.rotate(False)
                d.tap('Close '+title,exact=False);assert d.find('Original menu')
                menu_program(title)
                if title=='GrModels':d.tap('Man',timeout=30)
                assert d.find('Window menu: '+title,exact=False,timeout=40);time.sleep(2)
                shot('restored-'+title+'-'+engine+'-reopened')
                record(title+' '+engine,launch=True,portrait=True,landscape=True,input=True,customKeyboard=True,lifecycle=True,close=True,reopen=True)
            except Exception as exc:
                shot('FAIL-'+title+'-'+engine);record(title+' '+engine,error=str(exc),nodes=d.nodes());raise
    record('complete')
if __name__=='__main__':main()
