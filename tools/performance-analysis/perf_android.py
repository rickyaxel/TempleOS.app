#!/usr/bin/env python3
"""Plays a program on an Android device or emulator and collects the app's perf log.

The app is started with --ez perflog true, so the focused program prints one line per second:
  TempleOSMobile perf program=<id> fps=.. compose_ms=.. busy_pct=.. speaker_per_s=.. ui_fps=..
      ui_max_gap_ms=.. ui_janks=..
(ProgramApp.perfLine). The program is opened through the start menu like a user would, then
"played" by tapping its on-screen buttons on a fixed schedule (taps go through the
accessibility node bounds). Results: JSON with every per-second sample and a summary.

  perf_android.py -s 49c56f82 --menu Games... --program BomberGolf --seconds 20 \
      --taps "Space,Left arrow,Space,Right arrow" --out docs/performance/evidence/x.json
"""
import argparse
import json
import statistics
import sys
import time

from android_ui import Device, parse_perf


def summarize(samples):
    if not samples:
        return {}
    out = {}
    for k in ("fps", "compose_ms", "busy_pct", "speaker_per_s", "ui_fps", "ui_max_gap_ms", "ui_janks"):
        v = [s[k] for s in samples if isinstance(s.get(k), (int, float))]
        if v:
            out[k] = {"median": statistics.median(v), "min": min(v), "max": max(v)}
    return out


def run(d, menu, program, seconds, taps, landscape=False, period=0.7, apk=None, label=""):
    if apk:
        d.install(apk)
    if landscape:
        d.rotate(True)
    else:
        d.rotate(False)
    d.launch(clear=True, extras="--ez perflog true")
    time.sleep(2)
    d.tap("MENU")
    d.tap(menu)
    d.tap(program, timeout=10)
    # boot + program start; dismiss a start PopUp if the program shows one
    time.sleep(6)
    for ok in ("OKAY", "OK"):
        n = d.find(ok, timeout=0.5)
        if n:
            d.tap(ok)
    nodes = {n["label"]: n["bounds"] for n in d.nodes()}
    seq = [t for t in taps.split(",") if t]
    missing = [t for t in seq if t not in nodes]
    if missing:
        print("warning: buttons not on screen:", missing, file=sys.stderr)
    d.logcat_clear()
    t0 = time.time()
    i = 0
    tap_lat = []
    while time.time() - t0 < seconds:
        if seq:
            lbl = seq[i % len(seq)]
            b = nodes.get(lbl)
            if b:
                s0 = time.time()
                d.tap_xy((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
                tap_lat.append(time.time() - s0)
            i += 1
        time.sleep(period)
    lines = d.logcat("TempleOSMobile perf")
    samples = [p for p in (parse_perf(l) for l in lines) if p]
    shot = None
    res = {"device": d.serial, "label": label, "program": program, "landscape": landscape, "seconds": seconds,
           "taps": seq, "tap_cmd_s_median": statistics.median(tap_lat) if tap_lat else None,
           "samples": samples, "summary": summarize(samples)}
    d.key("KEYCODE_HOME")
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", default="emulator-5554")
    ap.add_argument("--menu", default="Games...")
    ap.add_argument("--program", required=True)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--taps", default="Space,Left arrow")
    ap.add_argument("--period", type=float, default=0.7)
    ap.add_argument("--landscape", action="store_true")
    ap.add_argument("--apk")
    ap.add_argument("--label", default="")
    ap.add_argument("--out")
    a = ap.parse_args()
    d = Device(a.serial)
    fg = d.foreground_package()
    if fg and fg not in ("com.digitalcircuitstudios.templeosapp", "com.google.android.apps.nexuslauncher", "com.android.launcher3") and "launcher" not in fg:
        print("refusing: %s is in the foreground on %s (another app may be under test)" % (fg, a.serial), file=sys.stderr)
        return 2
    r = run(d, a.menu, a.program, a.seconds, a.taps, a.landscape, a.period, a.apk, a.label)
    print(json.dumps(r["summary"], indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(r, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
