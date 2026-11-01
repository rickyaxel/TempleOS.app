#!/usr/bin/env python3
"""Pure Terry vs Pure Kotlin on an Android device: the same program, input and duration on each engine.

Each run force-stops the app and starts it without its saved windows (`--ez nosession true`), with
`--ez perflog true --es engine terry|native`, opens the program from the start menu, plays it by
tapping its on-screen buttons on a fixed schedule, and reads the app's per-second perf lines:

  TempleOSMobile perf program=<id> engine=<e> fps=.. compose_ms=.. busy_pct=.. cpu_pct=.. ...

ticks_per_s is the HolyC work done per second (budget ticks, the same count for the same work on both
engines): a program that runs flat out (no Sleep, e.g. Bounce) shows the native gain there. busy_pct is the kernel's own time (tasks + frame composition) per second of wall time; cpu_pct is
the whole process's CPU time (UI, audio, kernel and task threads) per second of wall time. Programs
run at TempleOS's frame rate on both engines, so the native gain shows mostly as less CPU (busy,
cpu) at the same fps; a program that cannot keep up shows it as higher fps.

Engines alternate (T N, N T, ...) to spread thermal and scheduling drift over both. The first
WARMUP seconds of every run are dropped (boot, JIT/AOT warm-up, first frames). The kernel boot time
(its "TempleOSMobile boot <name> <ms> ms" line) is recorded per run.

  perf_engines_android.py -s 49c56f82 --apk app-release.apk --repeats 3 --seconds 25 \\
      --program "Games...:BomberGolf:Space,Left arrow,Space,Right arrow" --out docs/performance/evidence/engines.json
"""
import argparse
import json
import re
import statistics
import sys
import time

from android_ui import Device, parse_perf

WARMUP = 4


def one(d, engine, menu, program, seconds, taps, period=0.7):
    # no `pm clear` (ColorOS refuses it): a fresh start without the saved windows instead
    d.launch(clear=False, extras="--ez perflog true --ez nosession true --es engine " + engine)
    time.sleep(2)
    d.logcat_clear()
    # the start menu: tap MENU again if the submenu entry is not there yet (slow first frame after a launch)
    for attempt in range(3):
        d.tap("MENU", timeout=10)
        if d.find(menu, timeout=4):
            break
        d.key("KEYCODE_BACK")
    d.tap(menu)
    # long submenus (Games...) scroll: page down until the program's row is on screen
    for _ in range(12):
        if d.find(program, timeout=1.5) or not d.find("Scroll menu down", timeout=0.3):
            break
        d.tap("Scroll menu down", settle=0.4)
    t_open = time.time()
    d.tap(program, timeout=10)
    time.sleep(5)
    for ok in ("OKAY", "OK", "RUN IN Pure Terry"):
        if d.find(ok, timeout=0.5):
            d.tap(ok)
    nodes = {n["label"]: n["bounds"] for n in d.nodes()}
    seq = [t for t in taps.split(",") if t]
    t0 = time.time()
    i = 0
    while time.time() - t0 < seconds:
        if seq:
            b = nodes.get(seq[i % len(seq)])
            if b:
                d.tap_xy((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
            i += 1
        time.sleep(period)
    lines = d.logcat("TempleOSMobile")
    samples = [p for p in (parse_perf(l) for l in lines) if p]
    boot = [int(m.group(1)) for m in (re.search(r"TempleOSMobile boot \S+ (\d+) ms", l) for l in lines) if m]
    d.key("KEYCODE_HOME")
    steady = samples[WARMUP:]
    return {"engine": engine, "program": program, "boot_ms": boot[-1] if boot else None,
            "engines_seen": sorted({s.get("engine") for s in samples if s.get("engine")}),
            "samples": samples, "steady": summarize(steady)}


def summarize(samples):
    out = {}
    for k in ("fps", "ticks_per_s", "compose_ms", "busy_pct", "cpu_pct", "speaker_per_s", "ui_fps", "ui_max_gap_ms", "ui_janks"):
        v = [s[k] for s in samples if isinstance(s.get(k), (int, float)) and s.get(k) >= 0]
        if v:
            out[k] = {"median": statistics.median(v), "mean": statistics.mean(v), "p95": sorted(v)[int(0.95 * (len(v) - 1))],
                      "min": min(v), "max": max(v), "n": len(v)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk")
    ap.add_argument("--program", action="append", required=True, help="menu:label:taps (taps comma-separated)")
    ap.add_argument("--seconds", type=float, default=25)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--out")
    a = ap.parse_args()
    d = Device(a.serial)
    fg = d.foreground_package()
    if fg and fg != "com.digitalcircuitstudios.templeosapp" and "launcher" not in fg:
        print("refusing: %s is in the foreground on %s" % (fg, a.serial), file=sys.stderr)
        return 2
    if a.apk:
        d.install(a.apk)
    d.rotate(False)
    info = {k: d.shell("getprop " + p).strip() for k, p in (("model", "ro.product.model"), ("android", "ro.build.version.release"),
                                                             ("soc", "ro.soc.model"), ("build", "ro.build.fingerprint"))}
    info["battery"] = d.shell("dumpsys battery | grep -E 'level|temperature|AC powered|USB powered'").strip().replace("\n", "; ")
    runs = []
    table = []
    for spec in a.program:
        menu, label, taps = (spec.split(":", 2) + ["", ""])[:3]
        per = {"terry": [], "native": []}
        for r in range(a.repeats):
            order = ("terry", "native") if r % 2 == 0 else ("native", "terry")
            for e in order:
                try:
                    res = one(d, e, menu, label, a.seconds, taps)
                except Exception as ex:  # a failed run is recorded, never silently dropped
                    print("%-14s %-6s FAILED: %s" % (label, e, ex), flush=True)
                    runs.append({"engine": e, "program": label, "repeat": r, "error": str(ex)})
                    d.key("KEYCODE_HOME")
                    save(a, d, info, table, runs)
                    continue
                res["repeat"] = r
                runs.append(res)
                per[e].append(res)
                save(a, d, info, table, runs)
                print("%-14s %-6s fps=%s ticks/s=%s busy=%s cpu=%s boot=%s" % (label, e, med(res, "fps"), med(res, "ticks_per_s"), med(res, "busy_pct"), med(res, "cpu_pct"), res["boot_ms"]), flush=True)
        row = {"program": label}
        for k in ("fps", "ticks_per_s", "busy_pct", "cpu_pct", "compose_ms"):
            for e in ("terry", "native"):
                vals = [med(x, k) for x in per[e] if med(x, k) is not None]
                row["%s_%s" % (e, k)] = statistics.median(vals) if vals else None
        for e in ("terry", "native"):
            b = [x["boot_ms"] for x in per[e] if x["boot_ms"] is not None]
            row["%s_boot_ms" % e] = statistics.median(b) if b else None
        if row.get("terry_cpu_pct") and row.get("native_cpu_pct"):
            row["cpu_ratio"] = row["terry_cpu_pct"] / row["native_cpu_pct"]
        if row.get("terry_ticks_per_s") and row.get("native_ticks_per_s"):
            row["throughput_ratio"] = row["native_ticks_per_s"] / row["terry_ticks_per_s"]
        if row.get("terry_busy_pct") and row.get("native_busy_pct"):
            row["busy_ratio"] = row["terry_busy_pct"] / row["native_busy_pct"]
        table.append(row)
    print(json.dumps(table, indent=1))
    save(a, d, info, table, runs)
    return 0


def save(a, d, info, table, runs):
    """Writes everything measured so far (after every run: an interrupted session keeps its data)."""
    if a.out:
        out = {"device": a.serial, "info": info, "seconds": a.seconds, "repeats": a.repeats, "warmup_s": WARMUP, "table": table, "runs": runs}
        with open(a.out, "w") as f:
            json.dump(out, f, indent=1)


def med(res, k):
    v = res["steady"].get(k)
    return v["median"] if v else None


if __name__ == "__main__":
    sys.exit(main())
