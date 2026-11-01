#!/usr/bin/env python3
"""Compare checkpoint files of the same scenario across engines and machines.

Each file is the JSON array a ScenarioRunner writes (host tests: purekotlin/build/parity/<id>.<engine>.json,
TempleCore/.build/parity/<id>.<engine>.json; devices: <tag>.<program>.<engine>.json from the bench mode).
The first file is the reference; every other file must agree at every checkpoint (frames, frame pixels,
sound events, console, budget ticks, finished, globals).

    tools/native-validation/compare_checkpoints.py NAME=FILE NAME=FILE ... [--json OUT]

Exit status 0 when all agree. A failure names the first differing checkpoint and field.
"""
import json
import sys

FIELDS = ["ticks", "frames", "frame", "sounds", "sound", "console", "finished", "globals"]


def first_difference(a, b):
    for x, y in zip(a, b):
        if x != y:
            fields = [f for f in FIELDS if x.get(f) != y.get(f)]
            return {"ms": x.get("ms"), "fields": fields, "reference": {f: x.get(f) for f in fields}, "other": {f: y.get(f) for f in fields}}
    if len(a) != len(b):
        return {"ms": None, "fields": ["checkpoint count"], "reference": len(a), "other": len(b)}
    return None


def main():
    args = [x for x in sys.argv[1:] if "=" in x and not x.startswith("--")]
    out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    runs = [(n, json.load(open(p))) for n, p in (a.split("=", 1) for a in args)]
    ref_name, ref = runs[0]
    result = {"reference": ref_name, "checkpoints": len(ref), "last_ms": ref[-1]["ms"] if ref else None,
              "final_ticks": ref[-1].get("ticks") if ref else None, "comparisons": []}
    ok = True
    for name, cps in runs[1:]:
        d = first_difference(ref, cps)
        ok = ok and d is None
        result["comparisons"].append({"name": name, "checkpoints": len(cps), "identical": d is None, "first_difference": d})
        print(f"{ref_name} vs {name}: " + ("identical at all %d checkpoints" % len(cps) if d is None else f"DIFFER {json.dumps(d)}"))
    if out:
        json.dump(result, open(out, "w"), indent=1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
