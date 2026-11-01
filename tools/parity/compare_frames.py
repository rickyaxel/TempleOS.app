#!/usr/bin/env python3
"""Cross-platform parity check: compares the final 640x480 indexed frames that
the Kotlin sweep (temple_os_kotlin/core/build/frames/<Dir>/*.idx) and the Swift
sweep (temple_os_swift/TempleCore/.build/frames/<Dir>/*.idx) recorded after
running the same program for 3 s of virtual time with identical input.

Usage: compare_frames.py Games [Graphics ...]
Prints one line per program: IDENTICAL, DIFF (with differing pixel count and
bounding box), or MISSING on one side. Exit status 1 if any frame differs.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KT = os.path.join(ROOT, 'temple_os_kotlin', 'core', 'build', 'frames')
SW = os.path.join(ROOT, 'temple_os_swift', 'TempleCore', '.build', 'frames')


def compare(which):
    kd, sd = os.path.join(KT, which), os.path.join(SW, which)
    names = sorted({f[:-4] for d in (kd, sd) if os.path.isdir(d) for f in os.listdir(d) if f.endswith('.idx')})
    same = diff = missing = 0
    for n in names:
        kp, sp = os.path.join(kd, n + '.idx'), os.path.join(sd, n + '.idx')
        if not (os.path.exists(kp) and os.path.exists(sp)):
            print(f'{which}/{n:24} MISSING ({"kotlin" if not os.path.exists(kp) else "swift"})')
            missing += 1
            continue
        a, b = open(kp, 'rb').read(), open(sp, 'rb').read()
        if a == b:
            print(f'{which}/{n:24} IDENTICAL')
            same += 1
            continue
        idx = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
        xs = [i % 640 for i in idx]
        ys = [i // 640 for i in idx]
        box = f'x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}' if idx else 'size differs'
        print(f'{which}/{n:24} DIFF {len(idx)} px ({100.0 * len(idx) / (640 * 480):.3f}%) {box}')
        diff += 1
    print(f'{which}: {same} identical, {diff} different, {missing} missing')
    return diff == 0 and missing == 0


if __name__ == '__main__':
    ok = all([compare(w) for w in (sys.argv[1:] or ['Games'])])
    sys.exit(0 if ok else 1)
