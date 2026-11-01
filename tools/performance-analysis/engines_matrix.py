#!/usr/bin/env python3
"""The program compatibility matrix of docs/native-translation/REPORT.md (section D).

  engines_matrix.py <kotlin parity-results.json> <swift parity-results-swift.json>

For every catalog program: the app's own status for it (runs / partial / unsupported, from the
catalog, which is about Pure Terry), the translation status (manifest), and the sweep results:
the Kotlin sweep compares Pure Terry and Pure Kotlin, the Swift sweep Pure Terry and Pure Swift and
both with the Kotlin runs. "=" means identical at every checkpoint.
"""
import json
import sys

ROOT = __file__.rsplit("/tools/", 1)[0]


def main():
    cat = json.load(open(ROOT + "/shared/program-manifests/catalog.json"))["programs"]
    man = {s["path"]: s for s in json.load(open(ROOT + "/shared/native-translation/manifest.json"))["sources"]}
    k = {p["id"]: p for p in json.load(open(sys.argv[1]))["programs"]}
    s = {p["id"]: p for p in json.load(open(sys.argv[2]))["programs"]}
    print("| Program | App status (Pure Terry) | Translation | Pure Terry Android vs Pure Kotlin | Pure Terry iOS vs Pure Swift | Across platforms |")
    print("|---|---|---|---|---|---|")
    counts = {}
    for c in sorted(cat, key=lambda c: (c["category"], c["title"].lower())):
        m = man.get(c["path"], {})
        st = m.get("status", "?")
        tr = {"translated": "translated", "not-compilable": "not compilable (both engines)", "translation-blocked": "blocked"}.get(st, st)
        if m.get("variants"):
            tr += " (%d variants)" % len(m["variants"])
        if m.get("requires_terry"):
            tr += ", needs Pure Terry for run-time compilation"
        kr, sr = k.get(c["id"]), s.get(c["id"])
        if st != "translated":
            kt = st_t = cross = "—"
        else:
            kt = "=" if kr and kr["status"] == "parity" else ("not run" if not kr else kr["status"] + ": " + kr.get("detail", "")[:60])
            sd = (sr or {}).get("detail", "")
            if not sr:
                st_t = cross = "not run"
            elif sr["status"] == "parity":
                st_t = cross = "="
            else:
                st_t = "=" if "swift terry vs swift native" not in sd else "differs"
                cross = "differs: " + sd[:60]
        key = (st, kt, st_t, cross)
        counts[key] = counts.get(key, 0) + 1
        print("| %s | %s | %s | %s | %s | %s |" % (c["title"], c["status"], tr, kt, st_t, cross))
    print()
    for key, n in sorted(counts.items(), key=lambda x: -x[1]):
        print("<!-- %d: %s -->" % (n, " / ".join(key)))


if __name__ == "__main__":
    main()
