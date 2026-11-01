#!/usr/bin/env python3
"""Exercise all five current mobile-wrapper tools on a real Android UI.

Only mutates a PaintTest-* file created by android_workflow.py. Reads the actual
sandbox GR after each UI Save; never clears app data or claims original editor parity.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'performance-analysis'))
from android_ui import Device, ADB, PKG


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--serial', required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--path', required=True)
    ap.add_argument('--resume-after-erase', action='store_true',
                    help='Resume an interrupted live session from this output directory, retaining its undo stack')
    ap.add_argument('--original-gr-only', action='store_true',
                    help='Load bundled Stadium GR and compare its saved body with the captured original VM output')
    a = ap.parse_args()
    assert a.path.startswith('C:/Home/PaintTest-') and a.path.endswith('.GR')
    assert '/' not in a.path[len('C:/Home/'):], 'only a generated test artwork is writable'
    a.out.mkdir(parents=True, exist_ok=True)
    d = Device(a.serial)
    result = {'scope': 'mobile wrapper only; actual UI input and saved logical GR pixels',
              'serial': a.serial, 'saved_path': a.path, 'checks': [],
              'started_utc': datetime.now(timezone.utc).isoformat()}

    def record(name, **details):
        result['checks'].append({'check': name, 'status': 'PASS', **details})
        print(name + ': PASS', flush=True)

    def menu(item):
        assert d.foreground_package() == PKG, 'another application interrupted the UI workflow'
        if not d.find(item, timeout=0):
            d.tap('Window menu: Paint', exact=False)
        d.tap(item)

    def enter(path):
        d.shell('input keyevent ' + ' '.join(['67'] * 80))
        d.shell('input text ' + shlex.quote(path)); d.key('KEYCODE_ENTER'); time.sleep(1)

    def screenshot(name):
        d.shot(str(a.out / (name + '.png')))

    def read(path, name):
        host = 'files/drive/files/' + path[len('C:/'):]
        data = subprocess.run([ADB, '-s', a.serial, 'exec-out', 'run-as', PKG, 'cat', host],
                              check=True, capture_output=True, timeout=30).stdout
        (a.out / (name + ('.GR.Z' if path.endswith('.Z') else '.GR'))).write_bytes(data)
        return data

    def decode(data):
        w, stride, h, flags = struct.unpack_from('<4i', data, 16)
        assert (w, h, flags) == (320, 240, 0), (w, stride, h, flags)
        assert len(data) == 32 + stride * h
        return b''.join(data[32 + y*stride:32 + y*stride+w] for y in range(h))

    def save(name):
        menu('Save'); time.sleep(.3)
        raw = read(a.path, name)
        return raw, decode(raw)

    def point(fx, fy):
        x0, y0, x1, y1 = d.find('Program picture: Paint')['bounds']
        return int(x0 + (x1-x0)*fx), int(y0 + (y1-y0)*fy)

    def drag(start, end):
        x0,y0 = point(*start); x1,y1 = point(*end)
        d.shell(f'input swipe {x0} {y0} {x1} {y1} 500')
        time.sleep(.5)

    try:
        assert d.find('Program picture: Paint'), 'run the basic workflow first'
        if a.original_gr_only:
            source = 'C:/Demo/Games/Stadium/StadiumBG.GR'
            target = a.path[:-3] + '-Stadium.GR'
            menu('Open file...'); enter(source)
            assert d.find('Window menu: Paint StadiumBG.GR', exact=False)
            screenshot('09-original-stadium-loaded')
            menu('Save as...'); enter(target)
            raw = read(target, '11-original-stadium')
            assert struct.unpack_from('<4i', raw, 16) == (641,648,473,0)
            repo = Path(__file__).resolve().parents[2]
            original = (repo / 'docs/paint-restoration/evidence/reference/original-stadium.idx').read_bytes()
            assert raw[32:] == original, 'mobile decode differs from original TempleOS DCLoad output'
            bundled = (repo / 'shared/bundled-fs/Demo/Games/Stadium/StadiumBG.GR').read_bytes()
            assert raw[:28] == bundled[:28], 'source metadata changed'
            record('bundled original compressed Stadium GR', width=641, height=473, stride=648,
                   original_vm_body_bytes_equal=len(original),
                   original_vm_body_sha256=hashlib.sha256(original).hexdigest(), saved_copy=target)
            result['status'] = 'PASS'
            return
        assert d.find('Window menu: Paint ' + a.path.split('/')[-1], exact=False)
        if a.resume_after_erase:
            prior = json.loads((a.out / 'tools-result.json').read_text())
            assert prior['status'] == 'FAIL' and len(prior['checks']) == 5
            (a.out / 'tools-interrupted.json').write_text(json.dumps(prior, indent=2)+'\n')
            result['checks'] = prior['checks']
            result['resumed_from'] = prior['finished_utc']
            filled_raw = (a.out / '03-fill.GR').read_bytes()
            filled = decode(filled_raw)
            assert read(a.path, 'resume-erased') == (a.out / '04-erase.GR').read_bytes()
        else:
            raw = read(a.path, '00-pen'); pen = decode(raw)
            assert pen.count(4) > 100 and set(pen) == {4, 15}
            record('red pen persisted as actual palette index 4', histogram=dict(Counter(pen)))

            d.tap('Tool LINE'); d.tap('Color Blue')
            drag((.25,.25), (.75,.25))
            _, line = save('01-line')
            blue = [i for i,c in enumerate(line) if c == 1]
            assert len(blue) > 100 and len({i//320 for i in blue}) == 1
            assert line.count(4) == pen.count(4)
            record('horizontal blue line', pixels=len(blue), logical_row=blue[0]//320)

            d.tap('Tool RECT'); d.tap('Color Green')
            drag((.1,.65), (.4,.9))
            _, rect = save('02-rectangle')
            green = [i for i,c in enumerate(rect) if c == 2]
            assert len(green) > 250 and rect[192*320+64] == 15
            xs = [i%320 for i in green]; ys = [i//320 for i in green]
            bounds = [min(xs), min(ys), max(xs), max(ys)]
            assert all(i%320 in (bounds[0],bounds[2]) or i//320 in (bounds[1],bounds[3]) for i in green)
            record('unfilled green rectangle', pixels=len(green), bounds=bounds)

            d.tap('Tool FILL'); d.tap('Color Yellow')
            d.tap_xy(*point(.2,.8)); time.sleep(.5)
            filled_raw, filled = save('03-fill')
            yellow = [i for i,c in enumerate(filled) if c == 14]
            assert len(yellow) > 1000
            assert all(bounds[0] < i%320 < bounds[2] and bounds[1] < i//320 < bounds[3] for i in yellow)
            assert filled.count(2) == rect.count(2) and filled[0] == 15
            record('yellow flood stays inside rectangle', pixels=len(yellow))
            screenshot('06-tools-drawn')

            d.tap('Tool ERASE')
            for n in (1,2,4):
                d.tap('Line thickness ' + str(n))
            assert d.find('Line thickness 8')
            drag((.4,.25), (.6,.25))
            _, erased = save('04-erase')
            assert erased.count(1) < filled.count(1) and erased.count(15) > filled.count(15)
            assert erased.count(14) == filled.count(14)
            record('eraser with thickness 8', removed_blue=filled.count(1)-erased.count(1))
        menu('Undo'); undo_raw, _ = save('05-undo-erase')
        assert undo_raw == filled_raw
        record('undo restores erased pixels', saved_gr_byte_exact=True)

        menu('Clear'); _, cleared = save('06-clear')
        assert set(cleared) == {15}
        record('clear', white_pixels=len(cleared))
        menu('Undo'); undo_raw, _ = save('07-undo-clear')
        assert undo_raw == filled_raw
        record('undo restores cleared artwork', saved_gr_byte_exact=True)

        archive_path = a.path + '.Z'
        menu('Save as...'); enter(archive_path)
        archive = read(archive_path, '08-archive')
        packed, expanded, kind = struct.unpack_from('<QQB', archive)
        assert (packed, expanded, kind) == (len(archive),len(filled_raw),1)
        assert archive[17:] == filled_raw
        record('GR.Z original CT_NONE archive', saved_gr_payload_byte_exact=True)

        d.tap('Close Paint', exact=False)
        d.tap('MENU'); d.tap('Paint')
        menu('Open file...'); enter(archive_path)
        assert d.find('Window menu: Paint ' + archive_path.split('/')[-1], exact=False)
        screenshot('07-archive-reopened')
        menu('Save')
        assert read(archive_path, '09-archive-reopened') == archive
        record('GR.Z reopen and resave', saved_archive_byte_exact=True)

        old_pid = d.shell('pidof ' + PKG).strip()
        d.key('KEYCODE_HOME'); time.sleep(1)
        d.launch(clear=False)
        new_pid = d.shell('pidof ' + PKG).strip()
        assert old_pid != new_pid
        assert d.find('Program picture: Paint')
        assert d.find('Window menu: Paint ' + archive_path.split('/')[-1], exact=False)
        menu('Save')
        assert read(archive_path, '10-process-restarted') == archive
        screenshot('08-process-restarted')
        record('saved artwork survives process restart', old_pid=old_pid, new_pid=new_pid,
               saved_archive_byte_exact=True, sha256=hashlib.sha256(archive).hexdigest())
        result['status'] = 'PASS'
    except Exception as e:
        result.update(status='FAIL', error=str(e))
        screenshot('tools-failure')
        raise
    finally:
        result['finished_utc'] = datetime.now(timezone.utc).isoformat()
        filename = 'original-gr-result.json' if a.original_gr_only else 'tools-result.json'
        (a.out / filename).write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
