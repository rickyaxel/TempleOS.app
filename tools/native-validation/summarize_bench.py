#!/usr/bin/env python3
"""Summarize BenchMode .jsonl results: one row per (program, engine, memory, duration).

    tools/native-validation/summarize_bench.py FILE.jsonl [...] [--markdown]

Warm-up runs are excluded. For each metric: median, min, max and the median absolute deviation (MAD) over
the samples; n is the sample count. Wall and CPU are host clocks of the device; virtual_ms is simulated
time. Memory: Android vm_hwm_kb (process peak RSS) / rss_peak_sampled_kb, iOS footprint_peak_sampled
(bytes). The device line (model, OS, conditions) is printed first for each file.
"""
import json
import statistics
import sys


def mad(v):
    m = statistics.median(v)
    return statistics.median([abs(x - m) for x in v])


def fmt(v, scale=1.0, unit=""):
    if not v:
        return "n/a"
    v = [x * scale for x in v]
    if len(v) == 1:
        return f"{v[0]:.1f}{unit}"
    return f"{statistics.median(v):.1f}{unit} [{min(v):.1f}-{max(v):.1f}, MAD {mad(v):.1f}]"


def main():
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    md = "--markdown" in sys.argv
    for f in files:
        groups, dev = {}, None
        for line in open(f):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("event") == "device":
                dev = d
            if d.get("event") != "run" or d.get("warmup"):
                continue
            groups.setdefault((d["program"].rsplit("/", 1)[-1], d["engine"], d.get("memmb"), d.get("virtual_ms")), []).append(d)
        if dev:
            name = dev.get("model") or dev.get("machine")
            print(f"# {f}: {name} {dev.get('android') or dev.get('os')} {dev.get('soc', '')} build={dev.get('build_type') or dev.get('config')} git={dev.get('git')}")
        if md:
            print("| Program | Engine | MiB | Simulated ms | n | Wall s | CPU s | Task wall s | Frame wall s | Boot ms | Peak memory MB | Same final state |")
            print("|---|---|---:|---:|---:|---|---|---|---|---|---|---|")
        for (prog, eng, mb, vms), rs in sorted(groups.items()):
            wall = [r["wall_ms"] for r in rs]
            cpu = [r["cpu_ms"] for r in rs]
            task = [r.get("task_wall_ms", 0) for r in rs]
            frame = [r.get("frame_wall_ms", 0) for r in rs]
            boot = [r.get("boot_ms", 0) for r in rs]
            mem = [r["vm_hwm_kb"] / 1024 for r in rs if r.get("vm_hwm_kb", -1) > 0] or [r["footprint_peak_sampled"] / 1e6 for r in rs if r.get("footprint_peak_sampled", -1) > 0]
            same = len({json.dumps(r.get("final_hash"), sort_keys=True) for r in rs}) == 1
            row = [prog, eng, str(mb), str(vms), str(len(rs)), fmt(wall, 1e-3), fmt(cpu, 1e-3), fmt(task, 1e-3), fmt(frame, 1e-3), fmt(boot), fmt(mem), "yes" if same else "NO"]
            print(("| " + " | ".join(row) + " |") if md else "  ".join(row))


if __name__ == "__main__":
    main()
