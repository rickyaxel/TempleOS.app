"""Explicit Android test targets; hardware uses only the side-by-side bench app."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/performance-analysis'))
import android_ui as ui

BENCH = 'com.digitalcircuitstudios.templeosapp.bench'


class HardwareDevice(ui.Device):
    def shell(self, cmd, **kwargs):
        if re.search(r'(^|[;&|])\s*(?:settings\s+(?:put|delete)\b|wm\s+(?:size|density)\s+\S|pm\s+(?:clear|uninstall)\b)', cmd):
            raise RuntimeError('Hardware tests preserve device settings and app data: ' + cmd)
        if cmd.startswith('am force-stop ') and cmd != 'am force-stop ' + BENCH:
            raise RuntimeError('Only the bench app may be stopped.')
        return super().shell(cmd, **kwargs)

    def install(self, apk):
        candidates = sorted((Path(ui.ADB).parents[1] / 'build-tools').glob('*/aapt2'))
        if not candidates:
            raise RuntimeError('aapt2 is required to verify the hardware test package.')
        badging = subprocess.check_output([str(candidates[-1]), 'dump', 'badging', str(apk)], text=True)
        if not re.search(r"^package: name='" + re.escape(BENCH) + r"'", badging, re.M):
            raise RuntimeError('Refusing to install a non-bench package on hardware.')
        super().install(apk)

    def launch(self, clear=False, extras=''):
        if clear:
            raise RuntimeError('Hardware app data must not be cleared.')
        super().launch(clear=False, extras=extras + ' --es inputOrientation portrait --es inputLanguage en-US')

    def rotate(self, landscape):
        # MainActivity's existing BENCH-only action changes this app, not global settings.
        self.shell('am start -W -f 0x20000000 -n ' + ui.ACT +
                   ' --es inputOrientation ' + ('landscape' if landscape else 'portrait'))
        time.sleep(1)
        return True

    def logcat_clear(self):
        raise RuntimeError('Hardware tests preserve shared device logs.')


def configure(description):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('serial')
    parser.add_argument('output', type=Path)
    parser.add_argument('--physical', action='store_true', help='Explicitly authorize the bench app on this hardware serial.')
    parser.add_argument('--cycles', type=int, default=5)
    args = parser.parse_args()
    emulator = bool(re.fullmatch(r'emulator-\d+', args.serial))
    if emulator == args.physical:
        parser.error('Use an emulator serial, or explicitly pass --physical for a hardware serial.')
    if not 1 <= args.cycles <= 20:
        parser.error('--cycles must be between 1 and 20.')
    ui.PKG = BENCH if args.physical else 'com.digitalcircuitstudios.templeosapp'
    ui.ACT = ui.PKG + '/io.github.templeosmobile.android.MainActivity'
    device = HardwareDevice(args.serial) if args.physical else ui.Device(args.serial)
    if args.physical and device.shell('getprop ro.kernel.qemu').strip() == '1':
        parser.error('--physical requires real hardware.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    variant = 'bench' if args.physical else 'debug'
    apk = ROOT / f'temple_os_kotlin/app/build/outputs/apk/{variant}/app-{variant}.apk'
    return args, device, output, apk
