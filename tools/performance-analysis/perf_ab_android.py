#!/usr/bin/env python3
"""Plays one program on an Android device with two or more builds, alternating, and compares them.

Uses the bench build type (com.digitalcircuitstudios.templeosapp.bench, installed beside the user's app; its
data is never the user's), started with --ez perflog true --ez nosession true. No device setting is changed:
the program runs in whatever orientation the device is in. Per run: the app's perf lines (ProgramApp.perfLine:
fps, compose_ms, busy_pct, cpu_pct = whole-process CPU per second, ui_fps, ui_max_gap_ms, ui_janks), the
UI thread's frame statistics from `dumpsys gfxinfo` (reset when play starts) and the process PSS at the end.

  perf_ab_android.py -s <serial> --apk base=base.apk --apk new=new.apk --program BomberGolf \\
      --taps "Space,Left arrow" --seconds 25 --runs 3 --out <dir>/bombergolf.json
"""
import argparse
import json
import re
import statistics
import sys
import time

import android_ui
from android_ui import Device, parse_perf

PKG = "com.digitalcircuitstudios.templeosapp.bench"
android_ui.PKG = PKG
android_ui.ACT = PKG + "/io.github.templeosmobile.android.MainActivity"


def gfxinfo(d):
    out = d.shell("dumpsys gfxinfo " + PKG, check=False)
    res = {}
    for key, pat in (("frames", r"Total frames rendered: (\d+)"), ("janky", r"Janky frames: (\d+)"),
                     ("p50", r"50th percentile: (\d+)ms"), ("p90", r"90th percentile: (\d+)ms"),
                     ("p95", r"95th percentile: (\d+)ms"), ("p99", r"99th percentile: (\d+)ms")):
        m = re.search(pat, out)
        if m:
            res[key] = int(m.group(1))
    return res


def pss_kb(d):
    m = re.search(r"TOTAL PSS:\s+(\d+)", d.shell("dumpsys meminfo " + PKG, check=False)) or \
        re.search(r"TOTAL\s+(\d+)", d.shell("dumpsys meminfo " + PKG, check=False))
    return int(m.group(1)) if m else None


def play(d, apk, menu, program, seconds, taps, period, engine):
    d.install(apk)
    d.shell("am force-stop " + PKG)
    extras = "--ez perflog true --ez nosession true" + (" --es engine " + engine if engine else "")
    d.shell("am start -W -n %s %s" % (android_ui.ACT, extras))
    time.sleep(3)
    d.tap("MENU")
    d.tap(menu)
    d.tap(program, timeout=10)
    time.sleep(8)  # boot and program start
    for ok in ("OKAY", "OK"):
        if d.find(ok, timeout=0.5):
            d.tap(ok)
    nodes = {n["label"]: n["bounds"] for n in d.nodes()}
    seq = [t for t in taps.split(",") if t]
    missing = [t for t in seq if t not in nodes]
    if missing:
        print("warning: buttons not on screen:", missing, file=sys.stderr)
    d.shell("dumpsys gfxinfo %s reset" % PKG, check=False)
    d.logcat_clear()
    t0 = time.time()
    i = 0
    while time.time() - t0 < seconds:
        b = nodes.get(seq[i % len(seq)]) if seq else None
        if b:
            d.tap_xy((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
        i += 1
        time.sleep(period)
    gfx = gfxinfo(d)
    samples = [p for p in (parse_perf(l) for l in d.logcat("TempleOSMobile perf")) if p][1:]  # first line: partial second
    pss = pss_kb(d)
    d.shell("am force-stop " + PKG)
    return {"samples": samples, "gfxinfo": gfx, "pssKb": pss}


def median(runs, key):
    v = [s[key] for r in runs for s in r["samples"] if isinstance(s.get(key), (int, float)) and s[key] >= 0]
    return {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v)} if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk", action="append", required=True, help="label=path, two or more")
    ap.add_argument("--menu", default="Games...")
    ap.add_argument("--program", required=True)
    ap.add_argument("--taps", default="Space,Left arrow")
    ap.add_argument("--period", type=float, default=0.7)
    ap.add_argument("--seconds", type=float, default=25)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--engine", choices=["terry", "native"])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    d = Device(a.serial)
    builds = [x.split("=", 1) for x in a.apk]
    res = {label: [] for label, _ in builds}
    for r in range(a.runs):
        for label, apk in builds:
            print("run %d %s" % (r + 1, label), file=sys.stderr)
            res[label].append(play(d, apk, a.menu, a.program, a.seconds, a.taps, a.period, a.engine))
    summary = {}
    for label, runs in res.items():
        summary[label] = {k: median(runs, k) for k in ("fps", "compose_ms", "busy_pct", "cpu_pct", "ui_fps", "ui_max_gap_ms", "ui_janks")}
        summary[label]["gfxinfo"] = [r["gfxinfo"] for r in runs]
        summary[label]["pssKb"] = [r["pssKb"] for r in runs]
    with open(a.out, "w") as f:
        json.dump({"program": a.program, "seconds": a.seconds, "runs": a.runs, "engine": a.engine, "summary": summary, "raw": res}, f, indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
