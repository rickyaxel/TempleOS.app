#!/usr/bin/env python3
"""Real Android UI regression for the mobile Paint wrapper. Never clears application data.

This does not claim historical editor/engine parity. Use a dedicated test device/emulator:
the workflow saves a unique C:/Home/PaintTest-*.GR through the actual UI.
--serial and --out are required.
--bench uses the isolated hardware test app and app-local orientation controls.
"""
import argparse
import json
import sys
import time
import uuid
import shlex
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'performance-analysis'))
from android_ui import Device, ACT
import android_ui as ui


def main():
    global ACT
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--serial', required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--bench', action='store_true', help='Use the side-by-side bench app without changing device settings')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    if a.bench:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'program-discovery'))
        from android_target import HardwareDevice, BENCH
        ui.PKG = BENCH
        ACT = ui.ACT = BENCH + '/io.github.templeosmobile.android.MainActivity'
        d = HardwareDevice(a.serial)
    else:
        d = Device(a.serial)
    paint_path = 'C:/Home/PaintTest-' + uuid.uuid4().hex[:8] + '.GR'
    original_rotation = d.shell('wm user-rotation').strip()
    original_settings = {key: d.shell('settings get system ' + key).strip()
                         for key in ('accelerometer_rotation', 'user_rotation')}
    rotation_changed = False

    def enter_path():
        d.shell('input keyevent ' + ' '.join(['67'] * 40))
        d.shell('input text ' + shlex.quote(paint_path))
        d.key('KEYCODE_ENTER')
        time.sleep(1)
    result = {'scope': 'mobile wrapper only', 'physical': not a.serial.startswith('emulator-'),
              'started_utc': datetime.now(timezone.utc).isoformat(),
              'saved_path': paint_path, 'build_configuration': 'Bench' if a.bench else 'Debug',
              'package': ui.PKG,
              'model': d.shell('getprop ro.product.model').strip(),
              'android': d.shell('getprop ro.build.version.release').strip(),
              'serial': a.serial, 'checks': [], 'original_rotation': original_rotation,
              'original_rotation_settings': original_settings}

    def rotate(landscape):
        nonlocal rotation_changed
        try:
            if a.bench:
                d.rotate(landscape)
            else:
                d.shell('wm user-rotation lock ' + ('1' if landscape else '0'))
                rotation_changed = True
            time.sleep(2)
            size = Image.open(shot('orientation-' + ('landscape' if landscape else 'portrait'))).size
            confirmed = (size[0] > size[1]) == landscape
            result['checks'].append({'orientation': 'landscape' if landscape else 'portrait',
                                     'status': 'PASS' if confirmed else 'FAIL', 'screen_pixels': size})
            assert confirmed, ('rotation did not take effect', landscape, size)
        except RuntimeError as e:
            result['checks'].append({'orientation': 'landscape' if landscape else 'portrait',
                                     'status': 'BLOCKED', 'reason': str(e)})
            print('Rotation blocked by device: ' + str(e), flush=True)

    def shot(name):
        if a.bench:
            state = d.shell('dumpsys input_method')
            assert 'mInputShown=true' not in state and 'isInputViewShown=true' not in state, 'Native IME visible'
        path = a.out / (name + '.png'); d.shot(str(path)); return path

    def pixels(name):
        n = d.find('Program picture: Paint')
        assert n, 'canvas accessibility node missing'
        x0, y0, x1, y1 = n['bounds']
        image = Image.open(shot(name)).convert('RGB').crop((x0+6, y0+6, x1-6, y1-6))
        data = getattr(image, 'get_flattened_data', image.getdata)()
        return {'nonwhite': sum(min(p) < 250 for p in data),
                'sha256': hashlib.sha256(image.tobytes()).hexdigest(), 'size': image.size}

    try:
        if a.bench:
            d.key('KEYCODE_WAKEUP')
            d.shell('wm dismiss-keyguard', check=False)
            d.launch(clear=False, extras='--ez nosession true --es engine native')
        else:
            d.launch(clear=False)
        rotate(False)
        d.tap('MENU'); d.tap('Paint')
        print('Paint launched; drawing red pen stroke', flush=True)
        before = pixels('01-initial')
        # A physical phone may have a transient system volume panel over the app.
        # New wrapper canvases are white: wait for that actual, unobstructed state.
        deadline = time.monotonic() + 15
        while before['nonwhite'] and time.monotonic() < deadline:
            time.sleep(1)
            before = pixels('01-initial')
        assert before['nonwhite'] == 0, ('new canvas is not visibly blank', before)
        d.tap('Tool PEN'); d.tap('Color Red')
        x0,y0,x1,y1 = d.find('Program picture: Paint')['bounds']
        x = lambda f: int(x0+(x1-x0)*f)
        y = lambda f: int(y0+(y1-y0)*f)
        d.shell(f'input swipe {x(.2)} {y(.3)} {x(.8)} {y(.7)} 700')
        after = pixels('02-drawn')
        assert after['nonwhite'] > before['nonwhite'] + 30, (before, after)
        result['checks'].append({'drawing': 'PASS', 'before': before, 'after': after})
        d.tap('Window menu: Paint', exact=False); d.tap('Save as...')
        enter_path(); shot('03-saved')
        print('Saved ' + paint_path + '; testing rotation and home/resume', flush=True)
        rotate(True)
        assert d.find('Program picture: Paint')
        shot('04-landscape')
        d.key('KEYCODE_HOME'); time.sleep(1); d.shell('am start -W -n ' + ACT)
        assert d.find('Program picture: Paint')
        rotate(False)
        resumed = pixels('04-resumed')
        assert resumed == after, ('canvas changed across orientation/home', after, resumed)
        result['checks'].append({'background_resume': 'PASS', 'canvas_unchanged': True})
        d.tap('Close Paint', exact=False)
        d.tap('MENU'); d.tap('Paint')
        d.tap('Window menu: Paint', exact=False); d.tap('Open file...')
        enter_path()
        reloaded = pixels('05-reloaded')
        assert reloaded == after, ('reloaded canvas differs', after, reloaded)
        result['checks'].append({'persistence': 'PASS', 'reloaded': reloaded,
                                 'canvas_sha256_equal': True})
        result['status'] = 'PARTIAL' if any(c.get('status') == 'BLOCKED' for c in result['checks']) else 'PASS'
        print('Workflow ' + result['status'], flush=True)
    except Exception as e:
        result['status'] = 'FAIL'; result['error'] = str(e)
        shot('failure')
        raise
    finally:
        if a.bench:
            d.shell('am start -W -f 0x20000000 -n ' + ACT + ' --es inputOrientation user', check=False)
            current_settings = {key: d.shell('settings get system ' + key).strip()
                                for key in original_settings}
            result['device_rotation_settings_unchanged'] = current_settings == original_settings
        if rotation_changed:
            try:
                # Restore both the mode and dormant rotation value, including auto-rotate devices.
                d.shell('wm user-rotation lock ' + original_settings['user_rotation'])
                if original_rotation == 'free':
                    d.shell('wm user-rotation free')
                restored = {key: d.shell('settings get system ' + key).strip()
                            for key in original_settings}
                result['rotation_settings_restored'] = restored == original_settings
            except Exception as e:
                result['rotation_restore_error'] = str(e)
        result['finished_utc'] = datetime.now(timezone.utc).isoformat()
        (a.out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
