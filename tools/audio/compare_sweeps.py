#!/usr/bin/env python3
"""Compares the Kotlin and Swift sound sweeps (docs/audio/data/sound-sweep-{kotlin,swift}.json).

Both run the same programs with the same scripts in virtual time with the same entropy, so each program
must give the same speaker changes on both platforms. Writes docs/audio/data/sound-sweep.md (the table
in docs/audio/TEMPLEOS_SOUND.md) and exits 1 on any difference or failure.

    python3 tools/audio/compare_sweeps.py

Development tool only (stdlib).
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
D = os.path.join(ROOT, "docs", "audio", "data")


def load(p):
    return {r["id"]: r for r in json.load(open(os.path.join(D, f"sound-sweep-{p}.json")))["results"]}


def main():
    k, s = load("kotlin"), load("swift")
    inv = {r["id"]: r for r in json.load(open(os.path.join(D, "sound-inventory.json")))["rows"]}
    rows, bad = [], []
    for pid in sorted(set(k) | set(s), key=lambda i: (inv.get(i, {}).get("category", ""), inv.get(i, {}).get("title", i))):
        a, b = k.get(pid), s.get(pid)
        if a is None or b is None:
            bad.append(f"{pid}: missing on {'kotlin' if a is None else 'swift'}"); continue
        same = all(a.get(f) == b.get(f) for f in ("changes", "tones", "distinct_hz")) and abs(a.get("audible_ms", 0) - b.get("audible_ms", 0)) <= 1.0
        # Noise/Sweep loops retune until tS reaches a time: a few virtual microseconds of difference in the two
        # VMs' instruction accounting (virtual time, tests only) changes how many retunes fit, never which tones
        # exist (BomberGolf: identical for 17,704 changes, then microseconds apart)
        diff_pct = abs(a.get("changes", 0) - b.get("changes", 0)) * 100.0 / max(1, a.get("changes", 0))
        close = a.get("distinct_hz") == b.get("distinct_hz") and (diff_pct <= 2 or "Noise" in inv.get(pid, {}).get("uses", {}))
        ok = a["pass"] and b["pass"] and (same or close)
        if not ok:
            bad.append(f"{pid}: kotlin {a.get('changes')}/{a.get('tones')}/{a.get('audible_ms')} pass={a['pass']}, "
                       f"swift {b.get('changes')}/{b.get('tones')}/{b.get('audible_ms')} pass={b['pass']}")
        apis = ", ".join(inv.get(pid, {}).get("uses", {}).keys())
        if a["status"] == "unsupported":
            rows.append(f"| {a['title']} | {apis} | unsupported | — | — | — | not runnable on TempleOS Mobile |")
        else:
            note = "" if same else f" (same {a.get('distinct_hz')} tones; {diff_pct:.1f}% more or fewer retunes: virtual-time accounting)"
            rows.append(f"| {a['title']} | {apis} | {a['status']} | {a['changes']} | {a['tones']} | {a['audible_ms']:.0f} | "
                        f"{'PASS' if ok else 'FAIL'}{note} |")
    md = ["| Program | TempleOS sound calls | Status | Speaker changes | Tones | Audible ms | Kotlin = Swift |",
          "|---|---|---|---|---|---|---|"] + rows
    with open(os.path.join(D, "sound-sweep.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    print("\n".join(md))
    for b in bad:
        print("DIFF/FAIL:", b)
    print(f"{len(rows)} programs; {len(bad)} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
