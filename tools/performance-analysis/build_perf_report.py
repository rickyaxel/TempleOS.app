#!/usr/bin/env python3
"""Per-program before/after table from two PerfTest JSON files (docs/performance).

  build_perf_report.py docs/performance/evidence/perf-kotlin-jvm-baseline.json \
      docs/performance/evidence/perf-kotlin-jvm-after.json > table.md

Each row: frames per second, mean / p95 frame composition (draw_it + ODEs + controls + publish), kernel
thread CPU share, speaker changes per second, and a status derived only from the numbers:
  improved   - frame rate up, or composition or CPU down by >= 15 % (and no metric 15 % worse)
  unchanged  - within 15 % (measurement noise on a shared host)
  regressed  - frame rate down or composition up by more than 15 %
  ended      - the program ended under both input scripts (console programs that finish at once)
"""
import json
import sys


def load(p):
    return {r["id"]: r for r in json.load(open(p))}


def status(b, a):
    if b["finished"] and a["finished"]:
        return "ended"
    worse = a["fps"] < b["fps"] * 0.85 or a["composeMeanMs"] > b["composeMeanMs"] * 1.15 + 0.3
    better = a["fps"] > b["fps"] * 1.15 or a["composeMeanMs"] < b["composeMeanMs"] * 0.85 - 0.1 or a["cpuPct"] < b["cpuPct"] * 0.85 - 1
    if worse and not better:
        return "regressed"
    if better and not worse:
        return "improved"
    if better and worse:
        return "mixed"
    return "unchanged"


def main():
    b, a = load(sys.argv[1]), load(sys.argv[2])
    print("| Program | Input | FPS | Compose mean ms | Compose p95 ms | Kernel CPU % | Speaker changes/s | Status |")
    print("|---|---|---|---|---|---|---|---|")
    counts = {}
    ended = lambda k: b[k]["finished"] and a.get(k, b[k])["finished"]
    for k in sorted(b, key=lambda k: (ended(k), -b[k]["cpuPct"])):
        if k not in a:
            continue
        x, y = b[k], a[k]
        st = status(x, y)
        counts[st] = counts.get(st, 0) + 1
        if st == "ended":
            # finished inside the warm-up second under both scripts: nothing to measure per frame
            print("| %s | %s | — | — | — | — | — | ended (finishes at once: console output) |" % (k, y["input"]))
            continue
        print("| %s | %s | %s → %s | %s → %s | %s → %s | %s → %s | %s → %s | %s |" % (
            k, y["input"], x["fps"], y["fps"], x["composeMeanMs"], y["composeMeanMs"], x["composeP95Ms"], y["composeP95Ms"],
            x["cpuPct"], y["cpuPct"], int(x["tonesPerSec"]), int(y["tonesPerSec"]), st))
    print()
    print("Status counts: " + ", ".join("%s %d" % kv for kv in sorted(counts.items())))


if __name__ == "__main__":
    main()
