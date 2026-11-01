#!/usr/bin/env python3
"""Markdown tables for docs/native-translation/REPORT.md from the engine benchmark evidence.

  engines_tables.py docs/native-translation/evidence

Reads bench-jvm.json and bench-swift.json (host: wall and CPU medians of alternating runs of the
same virtual-time work), android-engines*.json (perf_engines_android.py) and ios-sim-engines.json
(the simulator XCUITest runs, collected by --ios <dir-with-perf-*.json>), and prints one table each.
"""
import glob
import json
import os
import re
import statistics
import sys


def host(path, native_key):
    d = json.load(open(path))
    h = d["host"]
    print("Host: %s" % ", ".join("%s %s" % (k, v) for k, v in h.items()))
    print()
    print("| Program | Pure Terry ms | %s ms | Wall speedup | CPU speedup | Same work (ticks, frames) |" % native_key.title())
    print("|---|---:|---:|---:|---:|---|")
    for p in d["programs"]:
        print("| %s | %.1f | %.1f | %.2f× | %.2f× | %s (%d, %d) |" % (
            p["path"].removeprefix("C:/"), p["terry_wall_ms_median"], p["%s_wall_ms_median" % native_key], p["speedup_wall"],
            p["speedup_cpu"], "yes" if p["same_work"] else "NO", p["ticks"], p["frames"]))
    print()


def android(paths):
    rows = []
    info = None
    for path in paths:
        d = json.load(open(path))
        info = d["info"]
        rows += [r for r in d["table"] if r.get("terry_fps") is not None]
    print("Device: %s, Android %s, SoC %s; %s" % (info["model"], info["android"], info["soc"], info["battery"]))
    print()
    print("| Program | fps T / N | HolyC ticks/s T / N | Throughput N÷T | Kernel busy % T / N | App CPU % T / N | Boot ms T / N |")
    print("|---|---|---|---:|---|---|---|")
    for r in rows:
        print("| %s | %s / %s | %s / %s | %s | %s / %s | %s / %s | %s / %s |" % (
            r["program"], f(r["terry_fps"]), f(r["native_fps"]), f(r.get("terry_ticks_per_s")), f(r.get("native_ticks_per_s")),
            ("%.2f×" % r["throughput_ratio"]) if r.get("throughput_ratio") else "-",
            f(r["terry_busy_pct"]), f(r["native_busy_pct"]), f(r["terry_cpu_pct"]), f(r["native_cpu_pct"]),
            f(r["terry_boot_ms"]), f(r["native_boot_ms"])))
    print()


def ios(dirpath):
    runs = {}
    for fn in sorted(glob.glob(os.path.join(dirpath, "r*", "perf-*.json"))):
        d = json.load(open(fn))
        lines = d["lines"][3:]  # warm-up: the first 3 lines (boot, first frames)

        def med(k):
            v = [float(m.group(1)) for m in (re.search(k + r"=([\d.]+)", l) for l in lines) if m]
            return statistics.median(v) if v else None
        runs.setdefault(d["program"], {}).setdefault(d["engine"], []).append({k: med(k) for k in ("fps", "ticks_per_s", "busy_pct", "cpu_pct")})
    print("| Program | fps T / N | HolyC ticks/s T / N | Throughput N÷T | Kernel busy % T / N | App CPU % T / N | Runs |")
    print("|---|---|---|---:|---|---|---|")
    for prog, e in runs.items():
        def m(engine, k):
            v = [r[k] for r in e.get(engine, []) if r[k] is not None]
            return statistics.median(v) if v else None
        t, n = m("terry", "ticks_per_s"), m("native", "ticks_per_s")
        print("| %s | %s / %s | %s / %s | %s | %s / %s | %s / %s | %d + %d |" % (
            prog, f(m("terry", "fps")), f(m("native", "fps")), f(t), f(n), ("%.2f×" % (n / t)) if t and n else "-",
            f(m("terry", "busy_pct")), f(m("native", "busy_pct")), f(m("terry", "cpu_pct")), f(m("native", "cpu_pct")),
            len(e.get("terry", [])), len(e.get("native", []))))
    print()


def f(v):
    if v is None:
        return "-"
    return ("%.0f" % v) if abs(v) >= 100 else ("%.1f" % v).rstrip("0").rstrip(".")


def main():
    ev = sys.argv[1] if len(sys.argv) > 1 else "docs/native-translation/evidence"
    if os.path.exists(os.path.join(ev, "bench-jvm.json")):
        host(os.path.join(ev, "bench-jvm.json"), "kotlin")
    if os.path.exists(os.path.join(ev, "bench-swift.json")):
        host(os.path.join(ev, "bench-swift.json"), "swift")
    a = sorted(glob.glob(os.path.join(ev, "android-engines*.json")))
    if a:
        android(a)
    if len(sys.argv) > 3 and sys.argv[2] == "--ios":
        ios(sys.argv[3])


if __name__ == "__main__":
    main()
