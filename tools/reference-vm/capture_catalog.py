#!/usr/bin/env python3
"""Reference captures of every catalog program in the original TempleOS (QEMU).

For each program a fresh VM boots the official ISO, turns AutoComplete off, maximizes the
terminal (the mobile apps run every program in a maximized, bordered window), runs the program
with #include, and saves screendumps 3 s and 8 s after the command plus the PC speaker as WAV.

    python3 tools/reference-vm/capture_catalog.py OUTDIR [--jobs 4] [--only id1,id2] [--steps scenarios.json]

OUTDIR/<id>/{t3.png,t8.png,speaker.wav,log.json}. Development tool only.
"""
import argparse
import concurrent.futures as cf
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from templeos_vm import ROOT, TempleVM  # noqa: E402


def capture(pid, path, outdir, steps):
    d = os.path.join(outdir, pid)
    os.makedirs(d, exist_ok=True)
    vm = TempleVM(d, wav=os.path.join(d, "speaker.wav"))
    log = []
    try:
        vm.boot_to_shell()
        vm.cmd("AutoComplete;WinMax;", settle=1.5)
        t0 = time.time()
        vm.cmd(f'#include "{path}";', settle=0)
        log.append({"t": 0, "step": ["run", path]})
        plan = steps or [["wait", 3], ["shot", "t3"], ["wait", 5], ["shot", "t8"]]
        for st in plan:
            op = st[0]
            log.append({"t": round(time.time() - t0, 2), "step": st})
            if op == "wait":
                time.sleep(st[1])
            elif op == "shot":
                vm.shot(st[1])
            elif op == "key":
                vm.key(*st[1:])
            elif op == "hold":
                vm.key_down(st[1], True); time.sleep(st[2]); vm.key_down(st[1], False)
            elif op == "type":
                vm.type(st[1])
            elif op == "click":
                vm.click(st[1], st[2], "left")
            elif op == "rclick":
                vm.click(st[1], st[2], "right")
            elif op == "move":
                vm.mouse_to(st[1], st[2])
            elif op == "drag":
                vm.mouse_to(st[1], st[2]); vm.button("left", True)
                vm.mouse_to(st[3], st[4]); vm.button("left", False)
    except Exception as e:  # keep going with the other programs
        log.append({"error": repr(e)})
    finally:
        vm.quit()
        json.dump(log, open(os.path.join(d, "log.json"), "w"), indent=1)
    return pid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only", default="")
    ap.add_argument("--steps", default="", help="JSON {id: [steps]} to replace the default plan")
    a = ap.parse_args()
    cat = json.load(open(os.path.join(ROOT, "shared", "program-manifests", "catalog.json")))["programs"]
    steps = json.load(open(a.steps)) if a.steps else {}
    only = set(x for x in a.only.split(",") if x)
    todo = []
    for p in cat:
        if p["category"] == "example":  # written for this project: no TempleOS original
            continue
        if only and p["id"] not in only:
            continue
        todo.append((p["id"], "::/" + p["path"][3:], steps.get(p["id"])))
    os.makedirs(a.outdir, exist_ok=True)
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for pid in ex.map(lambda t: capture(t[0], t[1], a.outdir, t[2]), todo):
            print("done", pid, flush=True)


if __name__ == "__main__":
    main()
