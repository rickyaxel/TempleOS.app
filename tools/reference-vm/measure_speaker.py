#!/usr/bin/env python3
"""Measures the PC speaker pitch of the original TempleOS (reference VM).

Boots the official ISO in QEMU (tools/reference-vm/templeos_vm.py), runs one HolyC command line
that plays notes, records the speaker through QEMU's wav audiodev and prints the frequency found
in every 0.25 s window (zero crossings). QEMU's recording only advances while the speaker sounds,
so its time axis is not wall time: use it for pitch, not for durations.

    python3 tools/reference-vm/measure_speaker.py OUTDIR ['Snd(60);Sleep(3000);Snd;']

Development tool only. Evidence: docs/fidelity-audit/data/vm-observations.json (FA-33).
"""
import array
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from templeos_vm import TempleVM  # noqa: E402

DEFAULT = 'Snd(60);Sleep(3000);Snd;Sleep(500);Snd(48);Sleep(3000);Snd;"done\\n";'


def windows(wav, rate=44100, win_s=0.25):
    """(start s, low, high, Hz) per window of a 16-bit stereo WAV whose header QEMU may not have finished."""
    raw = open(wav, 'rb').read()[44:]
    a = array.array('h', raw[:len(raw) // 4 * 4])[::2]
    w = int(rate * win_s)
    for i in range(0, len(a) - w, w):
        x = a[i:i + w]
        lo, hi = min(x), max(x)
        m = (lo + hi) / 2
        cr = [j - 1 + (m - x[j - 1]) / (x[j] - x[j - 1]) for j in range(1, len(x)) if x[j - 1] < m <= x[j]]
        f = (len(cr) - 1) / ((cr[-1] - cr[0]) / rate) if len(cr) > 2 else 0.0
        yield i / rate, lo, hi, f


def main():
    out = sys.argv[1]
    cmd = sys.argv[2] if len(sys.argv) > 2 else DEFAULT
    os.makedirs(out, exist_ok=True)
    wav = os.path.join(out, 'speaker.wav')
    vm = TempleVM(out, wav=wav)
    try:
        vm.boot_to_shell()
        vm.cmd('AutoComplete;', settle=1.0)
        vm.cmd(cmd, settle=0)
        time.sleep(12)
        vm.shot('after')
    finally:
        vm.quit()
    for t, lo, hi, f in windows(wav):
        print(f'{t:6.2f}s  range {lo:6d}..{hi:6d}  {f:9.3f} Hz')
    sysfreq = 18333 * 65536 // 1000
    for ona in (60, 48):
        hz = 440 / 32 * 2 ** (ona / 12)
        period = max(1, min(65535, int(sysfreq / hz)))
        print(f'predicted ona {ona}: period {period}, {1193182 / period:.3f} Hz (equal temperament {hz:.3f} Hz)')


if __name__ == '__main__':
    main()
