#!/usr/bin/env python3
"""Exercise the actual side-by-side bench app without changing device settings or the user's app.

Touch keys are driven through accessibility; `input keyevent` separately exercises the hardware adapter.
A background sampler checks Android's IME state; app insets/animation counters catch transient visibility.
Usage: python3 tools/input-audit/android_keyboard_ui.py SERIAL OUTDIR [native|terry]
"""
import json
import os
from pathlib import Path
import re
import shlex
import statistics
import sys
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'performance-analysis'))
import android_ui

PKG = 'com.digitalcircuitstudios.templeosapp.bench'
android_ui.PKG = PKG
android_ui.ACT = PKG + '/io.github.templeosmobile.android.MainActivity'

NAMES = {' ': 'Space', '\n': 'Enter', '\t': 'Tab', '"': 'quote', "'": 'apostrophe', '`': 'backtick', ';': 'semicolon',
         ':': 'colon', ',': 'comma', '.': 'period', '(': 'left parenthesis', ')': 'right parenthesis', '{': 'left brace', '}': 'right brace',
         '[': 'left bracket', ']': 'right bracket', '<': 'less than', '>': 'greater than', '=': 'equals', '+': 'plus', '-': 'minus',
         '_': 'underscore', '/': 'slash', '\\': 'backslash', '|': 'vertical bar', '~': 'tilde', '!': 'exclamation mark', '@': 'at',
         '#': 'number sign', '$': 'dollar', '%': 'percent', '^': 'caret', '&': 'ampersand', '*': 'asterisk', '?': 'question mark'}


def main():
    serial, out = sys.argv[1:3]
    engine = sys.argv[3] if len(sys.argv) > 3 else 'native'
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    d = android_ui.Device(serial)
    report = {'engine': engine, 'steps': [], 'ime_samples': 0, 'ime_visible_samples': 0, 'ime_sample_errors': 0}
    report['device'] = {name: d.shell('getprop '+prop).strip() for name, prop in
                        [('model', 'ro.product.model'), ('api', 'ro.build.version.sdk'), ('release', 'ro.build.version.release')]}
    report['configured_ime'] = d.shell('settings get secure default_input_method').strip()
    done = threading.Event()

    def monitor():
        while not done.is_set():
            try:
                text = d.shell('dumpsys input_method', timeout=10)
                report['ime_samples'] += 1
                if re.search(r'\bmInputShown\s*=\s*true', text): report['ime_visible_samples'] += 1
            except Exception:
                report['ime_sample_errors'] += 1
            done.wait(0.1)
    worker = threading.Thread(target=monitor, daemon=True)
    worker.start()

    def check(name, keyboard=None):
        nodes = d.nodes()
        root = next((n['label'] for n in nodes if n['label'].startswith('TempleOS input;')), '')
        assert root, 'missing app input diagnostics'
        assert 'nativeImeViolations=0' in root, root
        assert report['ime_visible_samples'] == 0, 'Android reported a visible IME'
        if keyboard is True: assert 'templeKeyboard=1' in root, 'custom keyboard missing: '+root
        report['steps'].append({'step': name, 'state': root})
        print(name, root, flush=True)
        d.shot(str(out / (name + '.png')))

    def tap(label): d.tap(label, timeout=12)
    def labels(): return {n['label'] for n in d.nodes()}
    def type_touch(text):
        cache = {n['label']: n for n in d.nodes()}
        one_shot = False
        def press_cached(label):
            nonlocal cache
            if label not in cache: cache = {n['label']: n for n in d.nodes()}
            node = cache[label]
            x0,y0,x1,y1 = node['bounds']; d.tap_xy((x0+x1)//2,(y0+y1)//2)
        for char in text:
            label = NAMES.get(char, char)
            if label not in cache:
                if 'Letters' in cache:
                    press_cached('Letters'); cache = {n['label']: n for n in d.nodes()}
                if label not in cache and char.isalpha():
                    press_cached('Shift'); one_shot = True; cache = {n['label']: n for n in d.nodes()}
                if label not in cache and not char.isalpha() and 'Symbols' in cache:
                    press_cached('Symbols'); cache = {n['label']: n for n in d.nodes()}
            press_cached(label)
            if one_shot:
                one_shot = False; cache = {n['label']: n for n in d.nodes()}
    def start(label): tap('MENU'); tap(label); time.sleep(2)
    def close(title):
        node = next(n for n in d.nodes() if n['label'].startswith('Close ' + title))
        x0,y0,x1,y1 = node['bounds']; d.tap_xy((x0+x1)//2,(y0+y1)//2); time.sleep(1)
    def wait_text(fragment, timeout=25):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            if any(fragment in n['label'] for n in d.nodes()): return
            time.sleep(0.25)
        raise AssertionError('expected output not found: '+fragment)

    try:
        d.shell('input keyevent KEYCODE_WAKEUP')
        d.shell('am force-stop '+PKG)
        d.shell('am start -W -n '+android_ui.ACT+' --ez nosession true --es engine '+engine)
        time.sleep(4)
        check('00-desktop')
        start('Terminal'); time.sleep(2); check('01-terminal', True)
        type_touch('6*7;\n'); wait_text('ans=0x0000002A=42'); check('02-touch-command', True)
        tap('Hide keyboard'); check('03-hidden')
        tap('Show or hide keyboard'); check('04-reopened', True)
        # Physical/synthetic Android key events share the dispatcher; no IME connection is involved.
        d.shell('input text '+shlex.quote('8*8;')); d.key('KEYCODE_ENTER')
        wait_text('ans=0x00000040=64'); check('05-hardware-command', True)
        start('HolyC Editor'); check('06-editor', True)
        tap('Control'); type_touch('a'); type_touch('"OK\\n";')
        tap('SAVE'); check('07-save-dialog', True)
        backspace = next(n for n in d.nodes() if n['label']=='Backspace')['bounds']
        for _ in range(40): d.tap_xy((backspace[0]+backspace[2])//2,(backspace[1]+backspace[3])//2)
        type_touch('C:/Home/InputAudit.HC\n')
        if 'REPLACE' in labels(): tap('REPLACE')
        check('08-saved', True)
        tap('RUN'); wait_text('OK'); check('09-editor-run')
        close('InputAudit'); close('InputAudit.HC')
        resources = Path(__file__).resolve().parents[2] / 'shared'
        catalog = json.loads((resources / 'program-manifests/catalog.json').read_text())
        original_ids = {entry['programId'] for entry in json.loads((resources / 'runtime/games-menu/menu.json').read_text())['entries']}
        for program in ['BattleLines', 'Varoom', 'Maze', 'X-Caliber']:
            tap('MENU'); tap('Games...')
            info = next(entry for entry in catalog['programs'] if entry['title'] == program)
            # Maze is catalog-only in the reconstructed original menu. Select the actual
            # source-derived page instead of treating the historical list as the old popup.
            tap('Original menu' if info['id'] in original_ids else 'More programs')
            # The reconstructed Games page retains its scroll position between launches.
            # Each requested program must be found from the top, including earlier categories.
            d.key('KEYCODE_MOVE_HOME')
            for _ in range(12):
                if program in labels(): break
                tap('Scroll menu down')
            tap(program); time.sleep(4)
            for _ in range(3):
                if 'OKAY' in labels(): tap('OKAY')
                elif 'OK' in labels(): tap('OK')
            d.key('KEYCODE_DPAD_UP'); d.key('KEYCODE_SPACE'); time.sleep(1)
            assert any(n['label'].startswith('Program picture: '+program) for n in d.nodes()), 'game frame missing: '+program
            check('game-'+program)
            close(program)
        # Save/reopen through the application's own file browser and editor menu.
        start('Files')
        check('10-files')
        close('Files')
        d.key('KEYCODE_HOME'); time.sleep(2)
        d.shell('am start -n '+android_ui.ACT); time.sleep(2)
        check('11-foreground')
        start('Terminal'); check('12-focus-restored', True)
        d.key('KEYCODE_BACK'); check('13-back-hides-keyboard')
        tap('Show or hide keyboard'); check('14-back-reopened', True)
        # A fresh Activity/process restores its saved app-owned keyboard mode.
        d.key('KEYCODE_HOME'); time.sleep(2)
        d.shell('am force-stop '+PKG)
        d.shell('am start -W -n '+android_ui.ACT); time.sleep(4)
        check('15-process-restored', True)
        for orientation in ['landscape', 'portrait', 'landscape', 'portrait']:
            d.shell('am start -n '+android_ui.ACT+' --es inputOrientation '+orientation)
            time.sleep(2)
            check('rotation-'+str(len(report['steps']))+'-'+orientation, True)
        d.shell('am start -n '+android_ui.ACT+' --ez inputRecreate true')
        time.sleep(4)
        check('16-activity-recreated', True)
        for language in ['en-US', 'es-ES', 'fr-FR', 'de-DE', 'ja-JP', 'zh-CN', 'zh-TW', 'ar']:
            d.shell('am start -n '+android_ui.ACT+' --es inputLanguage '+language)
            time.sleep(1)
            check('locale-'+language, True)
            assert 'q' in labels(), 'TempleOS letter mapping changed with locale'
        d.shell('am start -n '+android_ui.ACT+' --es inputLanguage en-US --es inputOrientation user')
        time.sleep(2)
        type_touch('9*9;\n'); wait_text('ans=0x00000051=81')
        check('17-input-after-restoration', True)
        report['passed'] = True
    except Exception as error:
        report['passed'] = False; report['failure'] = str(error)
        print('FAIL:', error, flush=True)
        try:
            report['failure_nodes'] = [n['label'] for n in d.nodes()]
            d.shot(str(out/'failure.png'))
        except Exception: pass
    finally:
        done.set(); worker.join(timeout=15)
        (out/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    assert report['passed'], report.get('failure')


if __name__ == '__main__':
    main()
