#!/usr/bin/env python3
"""Side-by-side images of the original TempleOS (reference VM) and the app, shot by shot.

Inputs: a capture directory from tools/reference-vm/capture_catalog.py (VMDIR/<id>/<shot>.png)
and the app's frames from VmPlanFramesTest (temple_os_kotlin/core/build/vm-plan-frames/<id>/<shot>.png,
with <shot>.win holding the window rectangle the app shows). Writes OUTDIR/<id>/<shot>.png with the
VM picture on the left, the app's on the right and the app's window outlined, plus a per-shot
pixel difference count inside that window (palette indices, after mapping both to RGB). Random
sequences and timing differ between the two, so the numbers locate differences for a person to
look at; they are not a score.

    python3 tools/fidelity/compare_vm_frames.py VMDIR APPDIR OUTDIR [id ...]

Development tool only.
"""
import json
import os
import sys

from PIL import Image, ImageDraw


def main():
    vmdir, appdir, out = sys.argv[1:4]
    ids = sys.argv[4:] or sorted(os.listdir(appdir))
    report = {}
    for pid in ids:
        a = os.path.join(appdir, pid)
        v = os.path.join(vmdir, pid)
        if not os.path.isdir(a) or not os.path.isdir(v):
            continue
        for f in sorted(os.listdir(a)):
            if not f.endswith('.png') or not os.path.exists(os.path.join(v, f)):
                continue
            vm = Image.open(os.path.join(v, f)).convert('RGB')
            app = Image.open(os.path.join(a, f)).convert('RGB')
            win = [0, 0, 640, 480]
            wf = os.path.join(a, f[:-4] + '.win')
            if os.path.exists(wf):
                win = [int(x) for x in open(wf).read().split(',')]
            x0, y0, w, h = win
            diff = 0
            vp, ap = vm.load(), app.load()
            for y in range(y0, min(y0 + h, 480)):
                for x in range(x0, min(x0 + w, 640)):
                    if vp[x, y] != ap[x, y]:
                        diff += 1
            canvas = Image.new('RGB', (1290, 500), (40, 40, 40))
            canvas.paste(vm, (0, 20))
            canvas.paste(app, (650, 20))
            d = ImageDraw.Draw(canvas)
            d.text((4, 4), f'{pid} {f}: original TempleOS (VM)', fill=(255, 255, 255))
            d.text((654, 4), f'TempleOS Mobile (Kotlin kernel), window {win}, {diff} px differ', fill=(255, 255, 255))
            d.rectangle([650 + x0, 20 + y0, 650 + x0 + w - 1, 20 + y0 + h - 1], outline=(255, 0, 255))
            os.makedirs(os.path.join(out, pid), exist_ok=True)
            canvas.save(os.path.join(out, pid, f))
            report.setdefault(pid, {})[f[:-4]] = {'window': win, 'differing_pixels': diff, 'window_pixels': w * h}
    json.dump(report, open(os.path.join(out, 'report.json'), 'w'), indent=1)
    print(len(report), 'programs compared')


if __name__ == '__main__':
    main()
