#!/usr/bin/env python3
"""Exercise original sound programs through the custom keyboard on an Android emulator only."""
import hashlib
import json
from pathlib import Path
import sys
import time
import subprocess

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/performance-analysis'))
import android_ui as ui
sys.path.insert(0, str(ROOT / 'tools/audio'))
from analyze_capture import read_wav


def main():
    serial = sys.argv[1]
    assert serial.startswith('emulator-'), 'This workflow is simulator-only'
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    d = ui.Device(serial)
    d.install(str(ROOT / 'temple_os_kotlin/app/build/outputs/apk/debug/app-debug.apk'))
    report = {'serial': serial, 'scope': 'emulator only', 'steps': []}

    def record(**fields):
        report['steps'].append(fields)
        (out / 'report.json').write_text(json.dumps(report, indent=1) + '\n')
        print(fields, flush=True)

    def tap(label, exact=True, timeout=10):
        node = d.find(label, exact=exact, timeout=timeout)
        assert node, 'Missing control: ' + label
        x0, y0, x1, y1 = node['bounds']
        d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        time.sleep(.3)

    def menu(label):
        for _ in range(30):
            nodes = d.nodes()
            item = next((n for n in nodes if n['label'] == label), None)
            if item:
                x0, y0, x1, y1 = item['bounds'];d.tap_xy((x0+x1)//2, (y0+y1)//2);time.sleep(.4);return
            down = next((n for n in nodes if n['label'] == 'Scroll menu down'), None)
            if not down:
                break
            x0, y0, x1, y1 = down['bounds'];d.tap_xy((x0+x1)//2, (y0+y1)//2);time.sleep(.2)
        raise AssertionError('Missing menu entry: ' + label)

    def open_program(title):
        tap('MENU');tap('Games...')
        if title not in ['Psalmody', 'JukeBox']:
            tap('More programs')
        menu(title)
        assert d.find('Window menu: ' + title, exact=False, timeout=30)

    def keyboard():
        assert d.find('q', timeout=10), 'Full TempleOS keyboard is absent'
        assert 'mInputShown=true' not in d.shell('dumpsys input_method'), 'System keyboard opened'

    for engine in ['terry', 'native']:
        for title in ['ASCIIOrgan', 'Psalmody', 'JukeBox', 'WaterFowl', 'OhGreat', 'MorseCode']:
            try:
                d.rotate(False)
                d.launch(extras='--ez nosession true --ez soundcapture true --es engine ' + engine)
                open_program(title)
                if title in ['WaterFowl', 'OhGreat'] and not d.find('q', timeout=.1):
                    tap('Window menu: ' + title, exact=False);menu('Show keyboard')
                keyboard()
                if engine == 'native':
                    assert d.find(title + ' · Pure Kotlin', exact=False)
                d.shot(str(out / f'{title}-{engine}-portrait.png'))
                if title == 'JukeBox':
                    tap('7');tap('Space');time.sleep(1)
                elif title in ['WaterFowl', 'OhGreat']:
                    tap('a');time.sleep(1)
                else:
                    node = d.find('a');x0,y0,x1,y1=node['bounds'];x=(x0+x1)//2;y=(y0+y1)//2
                    d.shell(f'input swipe {x} {y} {x} {y} 350');time.sleep(1)
                if title == 'MorseCode':
                    assert d.find('-T', exact=False, timeout=10), 'Held custom key did not decode a dash into T'
                d.rotate(True);keyboard();d.shot(str(out / f'{title}-{engine}-landscape.png'))
                d.rotate(False)
                if title in ['ASCIIOrgan', 'MorseCode']:
                    tap('Shift');tap('Escape');time.sleep(1)
                tap('Close ' + title, exact=False)
                assert d.find('Original menu')
                if title in ['ASCIIOrgan', 'MorseCode']:
                    menu(title);keyboard();tap('Close ' + title, exact=False)
                d.key('KEYCODE_HOME');time.sleep(3)
                data = subprocess.check_output([ui.ADB, '-s', serial, 'exec-out', 'cat', '/sdcard/Android/data/' + ui.PKG + '/files/sound-capture-all.wav'])
                wav = out / f'{title}-{engine}.wav';wav.write_bytes(data)
                samples, rate = read_wav(str(wav))
                peak = max(map(abs, samples));silent = all(v == 0 for v in samples[-rate//10:])
                assert peak > .05 and silent, (title, peak, silent)
                record(program=title, engine=engine, customKeyboard=True, systemImeAbsent=True,
                       portrait=True, landscape=True, input=True, close=True,
                       reopen=title in ['ASCIIOrgan', 'MorseCode'], soundPeak=peak,
                       sampleRate=rate, audioSamples=len(samples), exitSilence=True,
                       wavSHA256=hashlib.sha256(data).hexdigest())
            except Exception as error:
                d.shot(str(out / f'FAIL-{title}-{engine}.png'))
                record(program=title, engine=engine, error=str(error), nodes=d.nodes())
                raise


if __name__ == '__main__':
    main()
