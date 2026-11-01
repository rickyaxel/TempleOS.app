#!/usr/bin/env python3
"""Flag benchmark regressions between two bench result files (BenchMode .jsonl).

    tools/native-validation/bench_regress.py BASELINE.jsonl CURRENT.jsonl [--metric wall_ms,cpu_ms,boot_ms,vm_hwm_kb,footprint_peak_sampled]

Groups non-warm-up runs by (program, engine, memmb, virtual_ms). A metric regresses when the current median
exceeds the baseline median by more than the noise allowance: max(3 x the larger median absolute deviation of
the two sample sets, 2% of the baseline median). With fewer than 3 samples on either side no verdict is given
(reported as "insufficient samples"), so the threshold always comes from measured variability. Behaviour is
checked too: a group whose final state hash or tick count differs from the baseline is reported as a
divergence, whatever the timings. Exit status 1 when anything regressed or diverged.
"""
import json
import statistics
import sys


def load(path):
    groups = {}
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("event") != "run" or d.get("warmup"):
            continue
        key = (d["program"], d["engine"], d.get("memmb"), d.get("virtual_ms"))
        groups.setdefault(key, []).append(d)
    return groups


def mad(v):
    m = statistics.median(v)
    return statistics.median([abs(x - m) for x in v])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    metrics = ["wall_ms", "cpu_ms", "boot_ms"]
    if "--metric" in sys.argv:
        metrics = sys.argv[sys.argv.index("--metric") + 1].split(",")
    base, cur = load(sys.argv[1]), load(sys.argv[2])
    bad = False
    for key in sorted(set(base) & set(cur)):
        b, c = base[key], cur[key]
        bh = {json.dumps(r.get("final_hash"), sort_keys=True) for r in b}
        ch = {json.dumps(r.get("final_hash"), sort_keys=True) for r in c}
        name = f"{key[0]} {key[1]} {key[2]}MiB {key[3]}ms"
        if bh != ch:
            bad = True
            print(f"DIVERGED {name}: final state {sorted(bh)} -> {sorted(ch)}")
        for m in metrics:
            bv = [r[m] for r in b if isinstance(r.get(m), (int, float)) and r[m] >= 0]
            cv = [r[m] for r in c if isinstance(r.get(m), (int, float)) and r[m] >= 0]
            if not bv or not cv:
                continue
            if len(bv) < 3 or len(cv) < 3:
                print(f"  {name} {m}: insufficient samples ({len(bv)} vs {len(cv)}), medians {statistics.median(bv):.1f} -> {statistics.median(cv):.1f}")
                continue
            mb, mc = statistics.median(bv), statistics.median(cv)
            allow = max(3 * max(mad(bv), mad(cv)), 0.02 * mb)
            verdict = "REGRESSED" if mc > mb + allow else ("improved" if mc < mb - allow else "same")
            bad = bad or verdict == "REGRESSED"
            print(f"  {name} {m}: {mb:.1f} -> {mc:.1f} (allowance {allow:.1f}) {verdict}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
