#!/usr/bin/env python3
"""Compare the shell screenshots written by the Kotlin and Swift ShellUiTest(s).

Both runtimes draw the TempleOS UI from the same core logic, so the same screen must be
pixel-identical. Run ./gradlew :core:test --tests '*ShellUiTest*' and
swift test --filter ShellUiTests first.

Usage: compare_ui_shots.py [kotlin_dir] [swift_dir]
"""
import os, sys
from PIL import Image, ImageChops

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
kdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'temple_os_kotlin/core/build/ui-shots')
sdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, 'temple_os_swift/TempleCore/.build/ui-shots')
# Differences that are expected; anything else is a parity defect.
KNOWN = {
    '05-about.png': 'Android also credits the Kotlin standard library (Apache-2.0), which iOS does not ship',
    '09-terminal.png': 'the measured run time ("0.000094s") and the cursor blink phase depend on the clock',
}
names = sorted(set(os.listdir(kdir)) & set(os.listdir(sdir)))
RED = (0xAA, 0x00, 0x00)


def clock_or_caret(a, b, x, y):
    """Pixels that depend on the wall clock: the top bar's clock (last 6 cells of the first
    text row) and the editor's 2 px RED caret, which blinks every 530 ms."""
    w = a.size[0]
    if y < 40 and x >= w - 6 * 8 - 8:
        return True
    return RED in (a.getpixel((x, y)), b.getpixel((x, y)))


bad = 0
for n in names:
    a = Image.open(os.path.join(kdir, n)).convert('RGB'); b = Image.open(os.path.join(sdir, n)).convert('RGB')
    if a.size != b.size:
        print(f'{n}: size {a.size} vs {b.size}'); bad += 1; continue
    box = ImageChops.difference(a, b).getbbox()
    d = ImageChops.difference(a, b)
    diff = 0 if box is None else sum(1 for x in range(box[0], box[2]) for y in range(box[1], box[3])
                                     if d.getpixel((x, y)) != (0, 0, 0) and not clock_or_caret(a, b, x, y))
    if diff and n in KNOWN:
        print(f'{n}: {diff} px differ (expected: {KNOWN[n]})'); continue
    print(f'{n}: {"identical" if diff == 0 else f"{diff} px differ in {box}"}')
    bad += diff > 0
print(f'{len(names)} screens compared, {bad} unexpected differences')
sys.exit(1 if bad or not names else 0)
