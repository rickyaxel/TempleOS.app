#!/usr/bin/env python3
"""Compare a device bench run's checkpoint files with the host references.

    tools/native-validation/device_vs_host.py DEVICE_DIR TAG [HOST_PARITY_DIR]

DEVICE_DIR holds <tag>.<program>.<engine>.json from a mode=parity run (device_bench.py); the host
references are purekotlin/build/parity/<catalog id>.<engine>.json (ParityTest.sweepAll) or
named-<script>-<program>.<engine>.json (NamedScenarioTest). A device run shorter than the host's is
compared on its checkpoints before its last one: the sweep script of a shorter run lacks the input
event at its own end time that the longer script has, so only equal durations agree at the end. Prints one line per program and engine; exit 1 on any difference.
"""
import glob, json, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main():
    dev, tag = sys.argv[1], sys.argv[2]
    host = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, "temple_os_kotlin/purekotlin/build/parity")
    cat = json.load(open(os.path.join(ROOT, "shared/program-manifests/catalog.json")))
    id_of = {p["path"]: p["id"] for p in cat["programs"]}
    by_name = {}
    # the run's own program paths (several programs are called Run.HC)
    jl = os.path.join(dev, f"{tag}.jsonl")
    for line in (open(jl) if os.path.exists(jl) else []):
        d = json.loads(line)
        if d.get("event") == "run" and d["program"] in id_of:
            by_name[d["program"].rsplit("/", 1)[1].rsplit(".", 1)[0]] = id_of[d["program"]]
    bad = n = 0
    files = sorted(glob.glob(os.path.join(dev, f"{tag}.*.json")))
    if not files:
        print(f"{tag}: no device checkpoints found")
        sys.exit(1)
    for f in files:
        n += 1
        prog, engine = os.path.basename(f)[len(tag) + 1:-5].rsplit(".", 1)
        cands = [os.path.join(host, f"named-{tag.split('-', 1)[-1]}-{prog}.{engine}.json"), os.path.join(host, f"{by_name.get(prog, prog)}.{engine}.json")]
        ref = next((c for c in cands if os.path.exists(c)), None)
        if ref is None:
            print(f"{prog} {engine}: no host reference"); bad += 1; continue
        a, b = json.load(open(ref)), json.load(open(f))
        upto = len(b) if len(b) == len(a) else len(b) - 1
        diff = next((x["ms"] for x, y in list(zip(a, b))[:upto] if x != y), None)
        if upto > 0 and diff is None and len(b) <= len(a):
            print(f"{prog:22} {engine:6} identical at {upto} checkpoints")
        else:
            bad += 1
            print(f"{prog:22} {engine:6} DIFFER at {diff} ms ({len(b)} device / {len(a)} host checkpoints)")
    print(f"{n - bad} of {n} identical")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
