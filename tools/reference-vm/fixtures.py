#!/usr/bin/env python3
"""Reference fixtures from the original TempleOS V5.03 (reference VM) and their comparison with the app.

Each fixture comes from an INSTRUMENTED DRIVER in tools/reference-vm/harness/ run through templeos_harness.py
(fw_cfg in, debugcon out). The drivers include the original program files from the CD unmodified where
possible; every deviation is listed in the fixture's "harness" section. Raw logs (harness.log = port 0xE9,
console.log = port 0xEA, meta.json = reproducibility metadata, PNG screendumps) are kept next to each fixture.

    python3 tools/reference-vm/fixtures.py rng            # -> shared/test-vectors/reference-vm/rng.json
    python3 tools/reference-vm/fixtures.py cartesian      # -> shared/test-vectors/dynexpr/cartesian-vm-results.json
    python3 tools/reference-vm/fixtures.py talons
    python3 tools/reference-vm/fixtures.py xcaliber
    python3 tools/reference-vm/fixtures.py compare APPDIR # APPDIR from ReferenceVmComparisonTest (-Dtempleos.vmcompare)

Development tool only.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from templeos_harness import HarnessRun, fnv1a64  # noqa: E402
from templeos_vm import ROOT  # noqa: E402

HARNESS = os.path.join(HERE, "harness")
VECTORS = os.path.join(ROOT, "shared", "test-vectors", "reference-vm")
DYNEXPR = os.path.join(ROOT, "shared", "test-vectors", "dynexpr")
CORPUS = os.path.join(DYNEXPR, "cartesian-corpus.json")
CART_INPUT = os.path.join(DYNEXPR, "cartesian-vm-input.txt")
WORK = os.environ.get("TEMPLEOS_VM_WORK", os.path.join(ROOT, "build", "reference-vm"))
MASK64 = (1 << 64) - 1


def rel(p):
    return os.path.relpath(p, ROOT)


def f64bits(v):
    return struct.unpack(">Q", struct.pack(">d", v))[0]


def bits2f64(b):
    return struct.unpack(">d", struct.pack(">Q", b & MASK64))[0]


def keep_logs(src, dst, names=("harness.log", "console.log", "meta.json"), pngs=True):
    os.makedirs(dst, exist_ok=True)
    for n in os.listdir(src):
        if n in names or (pngs and n.endswith(".png")):
            shutil.copy2(os.path.join(src, n), os.path.join(dst, n))


def run_meta(d):
    m = json.load(open(os.path.join(d, "meta.json")))
    return {k: m[k] for k in ("date_utc", "iso", "qemu_version", "qemu_args", "guest", "host", "files", "result")}


# ---------------------------------------------------------------- RNG

LCG_A, LCG_C = 6364136223846793005, 1442695040888963407


def lcg_model(seed, n):
    """Kernel/KMathB.HC with HolyC precedence (<< >> above *, & above ^, ^ above +):
    res = ((A*res) ^ ((res & 0xFFFFFFFF0000) >> 16)) + C, after Seed(seed) (non-timer)."""
    r, out = seed & MASK64, []
    for _ in range(n):
        r = ((((LCG_A * r) & MASK64) ^ ((r & 0xFFFFFFFF0000) >> 16)) + LCG_C) & MASK64
        out.append(r)
    return out


def model_values(fn, states):
    if fn in ("RandU64", "state_after_RandU64"):
        return states
    if fn == "RandU32":
        return [s & 0xFFFFFFFF for s in states]
    if fn == "RandU16":
        return [s & 0xFFFF for s in states]
    if fn == "RandI16":
        return [(s & 0xFFFF) - 0x10000 & MASK64 if s & 0x8000 else s & 0xFFFF for s in states]
    if fn == "Rand":
        return [f64bits((s & 0x3FFFFFFFFFFFFFFF) / float(0x4000000000000000)) for s in states]
    raise ValueError(fn)


def parse_rng(text):
    res = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) > 3 and p[0] == "RNG":
            res.setdefault(p[1], {})[p[2]] = [int(v, 16) for v in p[3:]]
    return res


def cmd_rng(a):
    out = os.path.join(WORK, "rng")
    if not a.reuse:
        HarnessRun(out, [os.path.join(HARNESS, "Rng.HC")], timeout=300).run()
    text = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
    vm = parse_rng(text)
    seeds = {}
    model_ok = True
    for seed_hex, fns in vm.items():
        seed = int(seed_hex, 16)
        states = lcg_model(seed, 64)
        entry = {}
        for fn, vals in fns.items():
            exp = model_values(fn, states[:len(vals)])
            ok = exp == vals
            model_ok &= ok
            entry[fn] = {"values": [f"{v:016X}" for v in vals], "matches_python_model": ok}
        seeds[seed_hex] = entry
    start = re.search(r"TASK-START rand_seed=(\S+) nontimer=(\d)", text)
    unseeded = re.search(r"UNSEEDED RandU64 (.*)", text)
    logs = os.path.join(VECTORS, "logs", "rng")
    keep_logs(out, logs)
    fixture = {
        "about": "TempleOS V5.03's own random number sequences, recorded in the original OS (reference VM). "
                 "INSTRUMENTED DRIVER tools/reference-vm/harness/Rng.HC: in the harness task it calls Seed(seed) "
                 "and then 64 x the function, starting from a fresh Seed(seed) for each function. Values are hex; "
                 "RandU32/RandU16 zero-extended, RandI16 sign-extended to 64 bits, Rand as the raw bits of the F64. "
                 "state_after_RandU64 = Fs->rand_seed after each of 4 RandU64 calls.",
        "source": "Kernel/KMathB.HC (RandU64, RandU32, RandU16, RandI16, Rand, Seed)",
        "semantics": {
            "generator": "per-task LCG: res=Fs->rand_seed; res=((6364136223846793005*res) ^ ((res&0xFFFFFFFF0000)>>16)) "
                         "+ 1442695040888963407 (HolyC precedence); unless TASKf_NONTIMER_RAND, res^=GetTSC; Fs->rand_seed=res",
            "outputs": "RandU64/RandI64 = res; RandU32 = res.u32[0]; RandU16 = res.u16[0]; RandI16 = res.i16[0]; "
                       "Rand = (res&0x3FFFFFFFFFFFFFFF)/ToF64(0x4000000000000000)",
            "seed": "Seed(n!=0) sets Fs->rand_seed=n and TASKf_NONTIMER_RAND (deterministic); Seed(0) clears the flag and "
                    "XORs the TSC into the seed (timer-based). Every new task gets Seed(0,task) in TaskInit "
                    "(Kernel/KTask.HC), so an unseeded task's sequence is not reproducible on TempleOS.",
            "harness_task_at_start": {"rand_seed": start.group(1) if start else None,
                                      "nontimer": int(start.group(2)) if start else None,
                                      "RandU64_before_any_Seed": unseeded.group(1).split() if unseeded else None},
        },
        "python_model_matches_vm": model_ok,
        "seeds": seeds,
        "vm_run": run_meta(out),
        "raw_logs": rel(logs),
    }
    os.makedirs(VECTORS, exist_ok=True)
    json.dump(fixture, open(os.path.join(VECTORS, "rng.json"), "w"), indent=1)
    print("rng.json written; python model matches VM:", model_ok)


# ---------------------------------------------------------------- Cartesian

FAULTY = ("divzero", "overflow", "invalid", "unsupported", "stress")


def corpus():
    return json.load(open(CORPUS))


def cart_lines(c, items):
    """items: list of (formula, sample_index or None for every sample)."""
    out = [f"S {f64bits(s):016X}" for s in c["samples"]]
    for f, si in items:
        if si is None:
            out.append(f"F {f['id']}\t{f['text']}")
        else:
            out.append(f"G {f['id']} {f64bits(c['samples'][si]):016X}\t{f['text']}")
    return "\n".join(out) + "\n"


def cmd_cartesian_input(a):
    c = corpus()
    open(CART_INPUT, "w", encoding="latin-1").write(cart_lines(c, [(f, None) for f in c["formulas"]]))
    print(CART_INPUT)


def parse_cart(text):
    begun, results = [], {}
    for line in text.splitlines():
        if line.startswith("B "):
            p = line.split(" ")
            begun.append((p[1], int(p[2], 16)))
        elif line.startswith("R "):
            p = line.split(" ", 9)
            fid, sb = p[1], int(p[2], 16)
            results[(fid, sb)] = {
                "result_bits": p[3], "x_bits": p[4], "y_bits": p[5], "y_last_bits": p[6],
                "except_ch": int(p[7], 16), "cc_fix": int(p[8]), "printed": p[9] if len(p) > 9 else "",
            }
    return begun, results


def except_name(ch):
    if not ch:
        return None
    b = ch.to_bytes(8, "little").rstrip(b"\0")
    try:
        return b.decode("ascii")
    except UnicodeDecodeError:
        return f"0x{ch:X}"


def cart_batch(name, c, items, max_runs=40):
    """Runs items in as many VM boots as needed: after a hang/debugger, restarts after the culprit."""
    results, incidents, runs = {}, [], []
    todo = list(items)
    run_no = 0
    sidx = {f64bits(s): i for i, s in enumerate(c["samples"])}
    while todo and run_no < max_runs:
        run_no += 1
        d = os.path.join(WORK, "cartesian", f"{name}-{run_no:02d}")
        inp = os.path.join(d, "cartesian.txt")
        os.makedirs(d, exist_ok=True)
        open(inp, "w", encoding="latin-1").write(cart_lines(c, todo))
        r = HarnessRun(d, [os.path.join(HARNESS, "Cartesian.HC")], data=[("cartesian.txt", inp)],
                       timeout=3600, silence=45)
        res = r.run()
        text = open(os.path.join(d, "harness.log"), "rb").read().decode("latin-1")
        begun, got = parse_cart(text)
        results.update(got)
        runs.append({"dir": d, "status": res["status"], "evaluated": len(got)})
        if res["status"] == "done" and "CART-END" in text:
            break
        # culprit: the last begun evaluation without a result
        culprit = next((b for b in reversed(begun) if b not in got), None)
        if culprit is None:
            incidents.append({"run": run_no, "status": res["status"], "note": "stopped without a pending evaluation"})
            if not begun:
                break
            culprit = begun[-1]
        incidents.append({"run": run_no, "status": res["status"], "formula": culprit[0],
                          "sample_bits": f"{culprit[1]:016X}", "dir": d})
        # rebuild the remaining work after the culprit
        flat = []
        for f, si in todo:
            for i in (range(len(c["samples"])) if si is None else [si]):
                flat.append((f, i))
        pos = next(i for i, (f, si) in enumerate(flat) if f["id"] == culprit[0] and si == sidx[culprit[1]])
        todo = [(f, si) for f, si in flat[pos + 1:] if (f["id"], f64bits(c["samples"][si])) not in results]
    return results, incidents, runs


def cmd_cartesian(a):
    c = corpus()
    groups = {"main": [f for f in c["formulas"] if f["cat"] not in FAULTY]}
    for cat in FAULTY:
        groups[cat] = [f for f in c["formulas"] if f["cat"] == cat]
    if a.only:
        groups = {k: v for k, v in groups.items() if k in a.only.split(",")}
    allres, incidents, runs = {}, [], {}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = {ex.submit(cart_batch, g, c, [(f, None) for f in fs]): g for g, fs in groups.items()}
        for fu in cf.as_completed(futs):
            g = futs[fu]
            r, inc, rn = fu.result()
            allres.update(r)
            incidents += [dict(i, group=g) for i in inc]
            runs[g] = rn
            print(g, "evaluated", len(r), "incidents", len(inc), flush=True)
    write_cartesian(c, allres, incidents, runs)


def write_cartesian(c, allres, incidents, runs):
    inc_by = {(i.get("formula"), i.get("sample_bits")): i for i in incidents if i.get("formula")}
    formulas = []
    counts = {}
    for f in c["formulas"]:
        rows = []
        for s in c["samples"]:
            sb = f64bits(s)
            r = allres.get((f["id"], sb))
            if r is None:
                inc = inc_by.get((f["id"], f"{sb:016X}"))
                outcome = inc["status"] if inc else "not-run"
                rows.append({"sample": s, "sample_bits": f"{sb:016X}", "outcome": outcome})
            else:
                exc = except_name(r["except_ch"])
                if exc == "Compiler":
                    outcome = "compile-error"
                elif exc:
                    outcome = "exception"
                else:
                    outcome = "accepted"
                row = {"sample": s, "sample_bits": f"{sb:016X}", "outcome": outcome,
                       "result_bits": r["result_bits"], "result_f64": repr(bits2f64(int(r["result_bits"], 16))),
                       "x_bits": r["x_bits"], "y_bits": r["y_bits"], "y_last_bits": r["y_last_bits"],
                       "except_ch": exc}
                if r["printed"]:
                    row["printed"] = r["printed"]
                if r["cc_fix"]:
                    row["cc_unqueued"] = True
                rows.append(row)
            counts[rows[-1]["outcome"]] = counts.get(rows[-1]["outcome"], 0) + 1
        formulas.append({"id": f["id"], "cat": f["cat"], "text": f["text"], "results": rows})
    logs = os.path.join(DYNEXPR, "cartesian-vm-logs")
    if os.path.isdir(logs):
        shutil.rmtree(logs)
    metas = {}
    for g, rn in runs.items():
        for r in rn:
            keep_logs(r["dir"], os.path.join(logs, os.path.basename(r["dir"])))
            metas[os.path.basename(r["dir"])] = {"status": r["status"], "evaluated": r["evaluated"]}
    first = runs[next(iter(runs))][0]["dir"]
    out = {
        "about": "What the original TempleOS V5.03 does with every formula of cartesian-corpus.json at every sample, "
                 "evaluated as ::/Demo/Graphics/Cartesian.HC evaluates its input (ExePrint(\"ToF64(%s);\",st) with the "
                 "F64 globals x, y, y_last). INSTRUMENTED DRIVER tools/reference-vm/harness/Cartesian.HC run in the "
                 "reference VM; x=sample, y=0, y_last=0 before every call; try/catch around ExePrint (Cartesian has "
                 "none: there an exception ends the program). outcome: accepted | compile-error (ExePutS caught "
                 "'Compiler', ExePrint returned 0) | exception (except_ch names it; Cartesian would stop) | debugger / "
                 "timeout / silent (the VM had to be restarted; see incidents). result_bits = the I64 that ExePrint "
                 "returned (Cartesian reads it as F64: result_f64). printed = what the call printed (compiler "
                 "messages included), escaped \\n \\\\ \\xHH. cc_unqueued: an exception skipped ExePutS's QueRem; "
                 "the harness unqueued the CCmpCtrl.",
        "corpus": rel(CORPUS), "corpus_fnv1a64": f"{fnv1a64(open(CORPUS, 'rb').read()):016X}",
        "input_file": rel(CART_INPUT),
        "outcome_counts": counts,
        "incidents": incidents,
        "runs": metas,
        "vm_run_example": run_meta(first),
        "raw_logs": rel(logs),
        "formulas": formulas,
    }
    json.dump(out, open(os.path.join(DYNEXPR, "cartesian-vm-results.json"), "w"), indent=1)
    print("cartesian-vm-results.json:", counts)


# ---------------------------------------------------------------- Talons

def iso_tree():
    d = os.path.dirname(os.path.dirname(os.path.abspath(__import__("templeos_vm").ISO)))
    return os.path.join(d, "templeos-iso")


def talons_norun(dst):
    """The CD's Talons.HC with its auto-run line removed (the only change)."""
    src = os.path.join(iso_tree(), "Demo", "Games", "Talons.HC")
    data = open(src, "rb").read()
    needle = b"\nTalons;\n"
    assert data.count(needle) == 1
    off = data.find(needle) + 1
    out = data[:off] + data[off + len(needle) - 1:]
    open(dst, "wb").write(out)
    import hashlib
    return {"original": "::/Demo/Games/Talons.HC", "original_sha256": hashlib.sha256(data).hexdigest(),
            "copy_sha256": hashlib.sha256(out).hexdigest(),
            "change": f"removed the 8 bytes 'Talons;\\n' at byte offset {off} (text line 1233, the auto-run call; "
                      f"the DolDoc binary sprite section after the text is unchanged)"}


def parse_kv(line):
    return {k: (int(v) if re.fullmatch(r"-?\d+", v) and len(v) != 16 else v) for k, v in re.findall(r"(\S+?)=(\S+)", line)}


def parse_talons(text):
    r = {"mem": [], "hash": {}, "sample": {}, "panels": None, "sizes": None}
    for line in text.splitlines():
        if line.startswith("MEM "):
            label = line.split()[1]
            r["mem"].append(dict(label=label, **parse_kv(line)))
        elif line.startswith("HASH "):
            p = line.split()
            r["hash"][p[1]] = {"fnv1a64": p[2], "row_blocks": p[3:]}
        elif line.startswith("SAMPLE "):
            p = line.split(" ", 2)
            r["sample"][p[1]] = p[2]
        elif line.startswith("PANELS "):
            r["panels"] = parse_kv(line)
        elif line.startswith("SIZES "):
            r["sizes"] = parse_kv(line)
        elif line.startswith("WATER "):
            r["water_cells"] = parse_kv(line)["cells"]
    return r


def cmd_talons(a):
    out = os.path.join(WORK, "talons")
    os.makedirs(out, exist_ok=True)
    norun = os.path.join(out, "TalonsNoRun.HC")
    change = talons_norun(norun)
    if not a.reuse:
        HarnessRun(out, [os.path.join(HARNESS, "Talons.HC")], data=[("TalonsNoRun.HC", norun)],
                   timeout=3600, silence=120).run()
    text = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
    r = parse_talons(text)
    logs = os.path.join(VECTORS, "logs", "talons")
    keep_logs(out, logs)
    mem = {m["label"]: m for m in r["mem"]}

    def delta(x, y, k="sys_code_bp.used"):
        return mem[y][k] - mem[x][k] if x in mem and y in mem else None
    fixture = {
        "about": "Talons (::/Demo/Games/Talons.HC) measured in the original TempleOS V5.03 (reference VM, 1 GiB, 2 CPUs). "
                 "INSTRUMENTED DRIVER tools/reference-vm/harness/Talons.HC including an instrumented copy of Talons.HC "
                 "(see harness.talons_copy). Memory numbers are TempleOS's own accounting in bytes: sys_code_bp/"
                 "sys_data_bp = the system block pools (with <=2 GiB RAM all memory is the code pool and sys_data_bp "
                 "is NULL; BlkPoolsInit in Kernel/Mem/BlkPool.HC), code_heap/data_heap = the harness task's heaps, "
                 "task_used/task_alloced = Adam/AMem.HC TaskMemUsed/TaskMemAlloced. JIT-compiled globals are "
                 "allocated on Fs->code_heap (Compiler/PrsStmt.HC). Hashes are FNV-1a 64 over the raw array bytes "
                 "(whole array, then 16 equal row blocks) after Seed(12345) in the harness task.",
        "harness": {"driver": "tools/reference-vm/harness/Talons.HC", "talons_copy": change, "seed": 12345,
                    "synthetic": "synthetic_* = CalcNormals on an elevation field filled by the driver's own integer "
                                 "LCG (s=s*6364136223846793005+1442695040888963407 from 0x9E3779B97F4A7C15; "
                                 "elevation=(s>>40)&0x3FFF), independent of Rand"},
        "sizes": r["sizes"],
        "memory": r["mem"],
        "memory_deltas_bytes": {
            "include (compile Talons.HC: code + globals)": delta("before-include", "after-include"),
            "terrain (InitElevations+CalcNormals, no allocation expected)": delta("after-include", "after-terrain"),
            "PreInit (large sprites)": delta("after-terrain", "after-PreInit"),
            "Init (panels, objects, depth buffer, birds)": delta("after-PreInit", "after-Init"),
            "CleanUp+PostCleanUp": delta("after-Init", "after-CleanUp"),
        },
        "water_cells": r.get("water_cells"),
        "hashes": r["hash"],
        "samples": r["sample"],
        "panels_after_Init": r["panels"],
        "vm_run": run_meta(out),
        "raw_logs": rel(logs),
    }
    small = os.path.join(VECTORS, "talons-memory-limits.json")
    if os.path.exists(small):
        fixture["guest_ram_limits"] = json.load(open(small))
    json.dump(fixture, open(os.path.join(VECTORS, "talons.json"), "w"), indent=1)
    print("talons.json written", json.dumps(fixture["memory_deltas_bytes"], indent=1))


def cmd_talons_mem(a):
    """Unmodified Talons at several guest RAM sizes; text through the all-task console copy."""
    res = []

    def one(m):
        out = os.path.join(WORK, "talons-mem", f"mem{m}")
        if a.reuse:
            r = json.load(open(os.path.join(out, "meta.json")))["result"]
        else:
            r = HarnessRun(out, [os.path.join(HARNESS, "TalonsUnmodified.HC")], mem=m, timeout=a.seconds,
                           silence=a.seconds + 60, shots=[15, 60, a.seconds - 5]).run()
        con = open(os.path.join(out, "console.log"), "rb").read().decode("latin-1")
        log = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
        dst = os.path.join(BLACKBOX, f"talons-mem{m}-console")
        keep_logs(out, dst)
        excepts = sorted(set(re.findall(r"Except:(\w+)", con)))
        return {"mem_mib": m, "vm_status": r["status"], "boot": [l for l in log.splitlines() if l.startswith(("BOOT-OK", "MEM"))],
                "exceptions_printed": excepts, "debugger_entered": "TempleOS Debugger" in con,
                "heartbeat_stopped": "HARNESS-DONE" not in log and r["status"] != "done" and
                                     log.rfind("HB ") < len(log) - 200,
                "initializing_seen": "Initializing" in con, "console_tail": con[-1500:], "evidence": rel(dst)}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(one, [int(x) for x in a.mem.split(",")]))
    out = {"about": "UNMODIFIED Talons (#include \"::/Demo/Games/Talons.HC\") in the reference VM at several guest RAM "
                    "sizes (2 CPUs). Loaded through the harness channel only to copy every task's printed text to "
                    "console.log (TalonsUnmodified.HC: HMirrorAll + one memory snapshot); vm_status 'timeout' = still "
                    "running in its game loop or halted when the host stopped it (see debugger_entered: the console "
                    "copy shows the TempleOS debugger; the CPU-1 heartbeat stops while the debugger holds the machine).",
           "runs": res}
    json.dump(out, open(os.path.join(VECTORS, "talons-memory-limits.json"), "w"), indent=1)
    for r in res:
        print(r["mem_mib"], r["vm_status"], r["exceptions_printed"])


# ---------------------------------------------------------------- X-Caliber

def parse_xc(text):
    frames = {}
    info = {}
    for line in text.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "STATE":
            frames.setdefault(p[1], {})["state"] = parse_kv(line)
        elif p[0] == "MASS":
            kv = parse_kv(line)
            frames.setdefault(p[1], {}).setdefault("masses", []).append(
                {"i": int(p[2]), "type": kv["type"], "x": kv["x"], "y": kv["y"], "DxDt": kv["DxDt"],
                 "DyDt": kv["DyDt"], "temperature": kv["temp"],
                 "x_f64": repr(bits2f64(int(kv["x"], 16))), "y_f64": repr(bits2f64(int(kv["y"], 16)))})
        elif p[0] == "SHIP":
            frames.setdefault(p[1], {}).setdefault("ships", []).append(dict(i=int(p[2]), **parse_kv(line)))
        elif p[0] == "MISSILE":
            frames.setdefault(p[1], {}).setdefault("missiles", []).append(dict(i=int(p[2]), **parse_kv(line)))
        elif p[0] == "HASH":
            frames.setdefault(p[1], {})["hash"] = parse_kv(line)
        elif p[0] in ("XC-START", "XC-END", "PIX", "LEVEL-UP"):
            info.setdefault(p[0], []).append(line)
    return frames, info


def cmd_xcaliber(a):
    runs = {"templeos_rand": [os.path.join(HARNESS, "XCaliberPhysics.HC")],
            "harness_lcg": [os.path.join(HARNESS, "XCaliberLcg.HC"), os.path.join(HARNESS, "XCaliberPhysics.HC")]}
    modes = {}
    for mode, files in runs.items():
        out = os.path.join(WORK, "xcaliber", mode)
        if not a.reuse:
            HarnessRun(out, files, timeout=3600, silence=120).run()
        text = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
        frames, info = parse_xc(text)
        logs = os.path.join(VECTORS, "logs", "xcaliber-" + mode)
        keep_logs(out, logs)
        modes[mode] = {"files": [rel(f) for f in files], "info": info, "frames": frames,
                       "vm_run": run_meta(out), "raw_logs": rel(logs)}
    same = all(modes["templeos_rand"]["frames"].get(k, {}).get("hash") == v.get("hash")
               for k, v in modes["harness_lcg"]["frames"].items())
    fixture = {
        "about": "X-Caliber (::/Apps/X-Caliber) replayed deterministically in the original TempleOS V5.03 (reference VM). "
                 "INSTRUMENTED DRIVER tools/reference-vm/harness/XCaliberPhysics.HC (its header lists every difference "
                 "from the real game: harness clock for tS, fixed window size, no real-time timeout, fixed ODE "
                 "tolerance 1e-6, scripted input: thrust frames 10-40, fire frame 30, left missile frame 60). The CD's "
                 "X-Caliber files are included unmodified. States at frames 0, 30, 60, 90, 120 (30 Hz): every mass's "
                 "x, y, DxDt, DyDt (raw F64 bits) in the ODE's mass order, ships, missiles; mass_hash = FNV-1a 64 over "
                 "x,y,DxDt,DyDt bytes of all masses in order; state_hash adds score and ship count. Mode templeos_rand "
                 "uses TempleOS's RandU16/Rand after Seed(12345); mode harness_lcg replaces them in the game's code by "
                 "the driver's own copy of the same LCG (so engines with a different Rand can be compared).",
        "harness_lcg_equals_templeos_rand": same,
        "floating_point_note": "TempleOS's compiler evaluates F64 expressions on the x87 FPU (80-bit registers, "
                               "precision control left at the FNINIT default: 64-bit mantissa); values are rounded to "
                               "IEEE double only when stored. QEMU TCG emulates the x87 in software (floatx80).",
        "modes": modes,
    }
    json.dump(fixture, open(os.path.join(VECTORS, "xcaliber-physics.json"), "w"), indent=1)
    print("xcaliber-physics.json written; harness LCG == TempleOS Rand:", same)


# ---------------------------------------------------------------- evaluation order probe

def parse_eo(text):
    return {l.split()[1]: l.split(" ", 2)[2] for l in text.splitlines() if l.startswith("EO ")}


def cmd_evalorder(a):
    out = os.path.join(WORK, "evalorder")
    if not a.reuse:
        HarnessRun(out, [os.path.join(HARNESS, "EvalOrder.HC")], timeout=300).run()
    text = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
    logs = os.path.join(VECTORS, "logs", "evalorder")
    keep_logs(out, logs)
    fixture = {
        "about": "Order in which the original TempleOS V5.03 HolyC compiler evaluates function arguments and operator "
                 "operands. INSTRUMENTED PROBE tools/reference-vm/harness/EvalOrder.HC: EoNote(tag) appends tag to a "
                 "decimal digit string, so order=21 means the second operand/argument was evaluated first.",
        "results": parse_eo(text),
        "vm_run": run_meta(out),
        "raw_logs": rel(logs),
    }
    json.dump(fixture, open(os.path.join(VECTORS, "eval-order.json"), "w"), indent=1)
    print(json.dumps(fixture["results"], indent=1))


# ---------------------------------------------------------------- x87 D3Unit probe

def round_bits(x, b):
    """Fraction x rounded to nearest (ties to even) with a b-bit significand."""
    from fractions import Fraction as Fr
    if x == 0:
        return Fr(0)
    sgn = -1 if x < 0 else 1
    a = abs(x)
    ex = a.numerator.bit_length() - a.denominator.bit_length()
    while Fr(2) ** ex > a:
        ex -= 1
    while Fr(2) ** (ex + 1) <= a:
        ex += 1
    scale = Fr(2) ** (b - 1 - ex)
    m = a * scale
    q, r = divmod(m.numerator, m.denominator)
    if 2 * r > m.denominator or (2 * r == m.denominator and q & 1):
        q += 1
    return sgn * Fr(q) / scale


def sqrt_bits(x, b):
    """Correctly rounded square root of a positive Fraction with a b-bit significand."""
    import math
    from fractions import Fraction as Fr
    k = 400 + b
    num = x.numerator * (1 << (2 * k))
    r = math.isqrt(num // x.denominator)
    exact = r * r * x.denominator == num
    return round_bits(Fr(r, 1 << k) + (0 if exact else Fr(1, 1 << (k + 2))), b)


def d3unit_models(x, y, z):
    """TempleOS D3Unit (Kernel/KMathA.HC: FSQRT/FDIVR on the x87 stack, 64-bit significand, one rounding to
    double on FSTP) and the IEEE-double sequence n=sqrt(x*x+y*y+z*z) rounded, then x/n rounded."""
    from fractions import Fraction as Fr
    c = [Fr(x), Fr(y), Fr(z)]
    s = c[0] ** 2 + c[1] ** 2 + c[2] ** 2      # exact for these small integers in both precisions
    n64, n53 = sqrt_bits(s, 64), sqrt_bits(s, 53)
    x87 = [f"{f64bits(float(round_bits(round_bits(v / n64, 64), 53))):016X}" for v in c]
    dbl = [f"{f64bits(float(round_bits(v / n53, 53))):016X}" for v in c]
    return x87, dbl


def cmd_x87(a):
    out = os.path.join(WORK, "x87probe")
    if not a.reuse:
        HarnessRun(out, [os.path.join(HARNESS, "X87Probe.HC")], timeout=300).run()
    text = open(os.path.join(out, "harness.log"), "rb").read().decode("latin-1")
    cells = []
    for m in re.finditer(r"XP cell (-?\d+) (-?\d+) D3Unit (\S+) (\S+) (\S+)", text):
        x, y = int(m.group(1)), int(m.group(2))
        x87, dbl = d3unit_models(x, y, -1)
        vmv = [m.group(3), m.group(4), m.group(5)]
        step = re.search(rf"XP cell {x} {y} s=\S+ Sqrt=(\S+) x/n=(\S+) y/n=(\S+) z/n=(\S+)", text)
        cells.append({"x": x, "y": y, "z": -1, "vm_D3Unit": vmv, "model_x87_64bit": x87, "model_ieee_double": dbl,
                      "vm_matches_x87_model": vmv == x87, "vm_step_by_step_double": list(step.groups()[1:]) if step else None,
                      "vm_step_by_step_matches_double_model": bool(step) and list(step.groups()[1:]) == dbl})
    logs = os.path.join(VECTORS, "logs", "x87probe")
    keep_logs(out, logs)
    fixture = {
        "about": "TempleOS D3Unit on the cells of Talons' synthetic terrain where the VM and the app differed. INSTRUMENTED "
                 "PROBE tools/reference-vm/harness/X87Probe.HC. Models (fixtures.py d3unit_models, exact rational "
                 "arithmetic): model_x87_64bit = FSQRT and FDIVR with a 64-bit significand (x87 precision control at "
                 "its FNINIT default) and one rounding to double on store; model_ieee_double = sqrt rounded to double, "
                 "then the division rounded to double (what a double-only engine computes).",
        "basic": re.search(r"XP basic (.*)", text).group(1) if re.search(r"XP basic (.*)", text) else None,
        "cells": cells,
        "vm_run": run_meta(out),
        "raw_logs": rel(logs),
    }
    json.dump(fixture, open(os.path.join(VECTORS, "x87-d3unit.json"), "w"), indent=1)
    print(json.dumps([(c["x"], c["y"], c["vm_matches_x87_model"], c["vm_step_by_step_matches_double_model"]) for c in cells]))


# ---------------------------------------------------------------- VM vs app interpreter

def splitmix64_seq(seed, n):
    out, s = [], seed & MASK64
    for _ in range(n):
        s = (s + 0x9E3779B97F4A7C15) & MASK64
        z = s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        out.append(z ^ (z >> 31))
    return out


def compare_rng(app_text):
    vm = json.load(open(os.path.join(VECTORS, "rng.json")))
    app = parse_rng(app_text)
    rows = []
    for seed_hex, fns in vm["seeds"].items():
        for fn, d in fns.items():
            v = [int(x, 16) for x in d["values"]]
            a = app.get(seed_hex, {}).get(fn)
            eq = a is not None and a == v
            first = None
            if a is not None and not eq:
                i = next(i for i in range(min(len(a), len(v))) if a[i] != v[i])
                first = {"index": i, "vm": f"{v[i]:016X}", "app": f"{a[i]:016X}"}
            rows.append({"seed": seed_hex, "fn": fn, "equal": eq, "equal_count": sum(1 for x, y in zip(a or [], v) if x == y),
                         "n": len(v), "first_mismatch": first})
    app_u64 = app.get("0000000000003039", {}).get("RandU64", [])
    explained = app_u64[:8] == splitmix64_seq(12345, 8)
    m = re.search(r"SEED 0000000000003039 ret=(\S+) rand_seed=(\S+) nontimer=(\d)", app_text)
    u = re.search(r"UNSEEDED RandU64 (.*)", app_text)
    unseeded = [int(x, 16) for x in u.group(1).split()] if u else []
    return {"rows": rows, "all_equal": all(r["equal"] for r in rows),
            "app_RandU64_after_Seed_12345_is_splitmix64_of_12345": explained,
            "app_RandU64_before_any_Seed": [f"{x:016X}" for x in unseeded],
            "app_RandU64_before_any_Seed_is_splitmix64_from_boot_entropy_12345": unseeded == splitmix64_seq(12345, len(unseeded)) if unseeded else None,
            "app_task_after_Seed_12345": {"ret": m.group(1), "rand_seed": m.group(2), "nontimer": int(m.group(3))} if m else None}


def compare_cartesian(app_text):
    vm = json.load(open(os.path.join(DYNEXPR, "cartesian-vm-results.json")))
    _, app = parse_cart(app_text)
    by_cat, mismatches = {}, []
    for f in vm["formulas"]:
        for r in f["results"]:
            key = (f["id"], int(r["sample_bits"], 16))
            a = app.get(key)
            c = by_cat.setdefault(f["cat"], {"n": 0, "equal": 0, "missing": 0})
            c["n"] += 1
            if a is None:
                c["missing"] += 1
                mismatches.append({"id": f["id"], "text": f["text"], "sample": r["sample"], "vm_outcome": r["outcome"],
                                   "app": "no result (harness stopped or skipped)"})
                continue
            a_exc = except_name(a["except_ch"])
            fields = {"result_bits": (r.get("result_bits"), a["result_bits"]), "x_bits": (r.get("x_bits"), a["x_bits"]),
                      "y_bits": (r.get("y_bits"), a["y_bits"]), "y_last_bits": (r.get("y_last_bits"), a["y_last_bits"]),
                      "except_ch": (r.get("except_ch"), a_exc)}
            diff = {k: {"vm": v[0], "app": v[1]} for k, v in fields.items() if v[0] != v[1]}
            if not diff:
                c["equal"] += 1
            else:
                for k in ("result_bits", "x_bits", "y_bits", "y_last_bits"):
                    if k in diff and diff[k]["vm"]:
                        diff[k]["vm_f64"] = repr(bits2f64(int(diff[k]["vm"], 16)))
                        diff[k]["app_f64"] = repr(bits2f64(int(diff[k]["app"], 16)))
                mismatches.append({"id": f["id"], "cat": f["cat"], "text": f["text"], "sample": r["sample"],
                                   "sample_bits": r["sample_bits"], "vm_outcome": r["outcome"], "diff": diff,
                                   "vm_printed": r.get("printed", "")[:300]})
    total = sum(c["n"] for c in by_cat.values())
    eq = sum(c["equal"] for c in by_cat.values())
    return {"total": total, "equal": eq, "by_category": by_cat, "mismatches": mismatches}


def compare_talons(app_text):
    vm = json.load(open(os.path.join(VECTORS, "talons.json")))
    app = parse_talons(app_text)
    rows = []
    for name, h in vm["hashes"].items():
        a = app["hash"].get(name)
        blocks = None
        if a:
            blocks = [i for i, (x, y) in enumerate(zip(h["row_blocks"], a["row_blocks"])) if x != y]
        rows.append({"array": name, "vm": h["fnv1a64"], "app": a["fnv1a64"] if a else None,
                     "equal": bool(a) and a["fnv1a64"] == h["fnv1a64"], "differing_row_blocks": blocks})
    return {"hashes": rows, "vm_samples": vm["samples"], "app_samples": app["sample"],
            "vm_panels": vm["panels_after_Init"], "app_panels": app["panels"],
            "vm_water_cells": vm.get("water_cells"), "app_water_cells": app.get("water_cells"),
            "app_memory": app["mem"], "app_sizes": app["sizes"]}


def compare_xc(mode, app_text):
    vm = json.load(open(os.path.join(VECTORS, "xcaliber-physics.json")))["modes"][mode]
    af, ainfo = parse_xc(app_text)
    rows = []
    for fr, d in sorted(vm["frames"].items(), key=lambda kv: int(kv[0])):
        a = af.get(fr)
        row = {"frame": int(fr), "vm_mass_hash": d["hash"]["mass_hash"], "app_mass_hash": a["hash"]["mass_hash"] if a else None,
               "vm_masses": d["hash"]["masses"], "app_masses": a["hash"]["masses"] if a else None,
               "vm_score": d["state"]["score"], "app_score": a["state"]["score"] if a else None,
               "vm_steps": d["state"]["steps"], "app_steps": a["state"]["steps"] if a else None}
        row["equal"] = bool(a) and row["vm_mass_hash"] == row["app_mass_hash"] and row["vm_masses"] == row["app_masses"]
        if a and not row["equal"]:
            for vmm, am in zip(d.get("masses", []), a.get("masses", [])):
                dif = {k: {"vm": vmm[k], "app": am[k], "vm_f64": repr(bits2f64(int(vmm[k], 16))),
                           "app_f64": repr(bits2f64(int(am[k], 16)))}
                       for k in ("x", "y", "DxDt", "DyDt") if vmm[k] != am[k]}
                if dif or vmm["type"] != am["type"]:
                    row["first_differing_mass"] = {"index": vmm["i"], "vm_type": vmm["type"], "app_type": am["type"], "fields": dif}
                    break
        rows.append(row)
    return {"frames": rows, "app_info": ainfo, "all_equal": all(r["equal"] for r in rows)}


def cmd_compare(a):
    d = a.appdir
    res = {"about": "Reference VM (original TempleOS V5.03) vs the app's interpreter (Pure Terry on the JVM, "
                    "ReferenceVmComparisonTest) on the same harness files.", "app_runs": {}}
    for n in ("rng", "evalorder", "x87probe", "cartesian", "talons", "xcaliber-templeos_rand", "xcaliber-harness_lcg"):
        p = os.path.join(d, n + ".txt")
        if not os.path.exists(p):
            continue
        t = open(p, encoding="latin-1").read()
        mp = os.path.join(d, n + ".meta.json")
        res["app_runs"][n] = json.load(open(mp)) if os.path.exists(mp) else {}
        res["app_runs"][n]["completed"] = "HARNESS-DONE" in t
        if n == "x87probe":
            vm = json.load(open(os.path.join(VECTORS, "x87-d3unit.json")))
            rows = []
            for c in vm["cells"]:
                m = re.search(rf"XP cell {c['x']} {c['y']} D3Unit (\S+) (\S+) (\S+)", t)
                appv = list(m.groups()) if m else None
                rows.append({"cell": [c["x"], c["y"], -1], "vm": c["vm_D3Unit"], "app": appv,
                             "equal": appv == c["vm_D3Unit"], "app_matches_ieee_double_model": appv == c["model_ieee_double"],
                             "vm_matches_x87_model": c["vm_matches_x87_model"]})
            res["x87probe"] = {"rows": rows, "all_equal": all(r["equal"] for r in rows)}
        elif n == "evalorder":
            vm = json.load(open(os.path.join(VECTORS, "eval-order.json")))["results"]
            app = parse_eo(t)
            res["evalorder"] = {"rows": [{"probe": k, "vm": v, "app": app.get(k), "equal": app.get(k) == v}
                                         for k, v in vm.items()]}
            res["evalorder"]["all_equal"] = all(r["equal"] for r in res["evalorder"]["rows"])
        elif n == "rng":
            res["rng"] = compare_rng(t)
        elif n == "cartesian":
            res["cartesian"] = compare_cartesian(t)
        elif n == "talons":
            res["talons"] = compare_talons(t)
        else:
            res[n] = compare_xc(n.split("-", 1)[1], t)
        shutil.copy2(p, os.path.join(VECTORS, "logs", "app-" + n + ".txt"))
    json.dump(res, open(os.path.join(VECTORS, "app-comparison.json"), "w"), indent=1)
    print(json.dumps({k: (v.get("all_equal") if isinstance(v, dict) and "all_equal" in v else
                          (f'{v["equal"]}/{v["total"]}' if isinstance(v, dict) and "total" in v else None))
                      for k, v in res.items() if k not in ("about", "app_runs")}, indent=1))


# ---------------------------------------------------------------- black-box runs of the unmodified programs

BLACKBOX = os.path.join(ROOT, "docs", "native-validation", "vm")

# Steps: ["cmd", text, settle] types a line + ENTER; ["type", text]; ["key", qcode...]; ["hold", qcode, s];
# ["wait", s]; ["shot", name]. Times in the log are seconds after the program's #include line.
SCENARIOS = {
    "cartesian": {"program": "::/Demo/Graphics/Cartesian.HC", "steps": [
        ["wait", 4], ["shot", "cartesian-prompt"],
        ["type", "2*x\n"], ["wait", 25], ["shot", "cartesian-2x"], ["key", "spc"], ["wait", 3],
        ["type", "Sin(x/20)*100\n"], ["wait", 25], ["shot", "cartesian-sin"], ["key", "spc"], ["wait", 3],
        ["type", "x*x/100\n"], ["wait", 25], ["shot", "cartesian-xx"], ["key", "esc"], ["wait", 3],
        ["shot", "cartesian-after-esc"]]},
    "xcaliber": {"program": "::/Apps/X-Caliber/Run.HC", "steps": [
        ["wait", 6], ["shot", "xcaliber-t06-popup"], ["key", "esc"], ["wait", 3], ["shot", "xcaliber-t09-level"],
        ["key", "ret"], ["wait", 2], ["shot", "xcaliber-t11"], ["hold", "up", 1.0], ["key", "spc"], ["wait", 2],
        ["shot", "xcaliber-t15-after-thrust-fire"], ["wait", 5], ["shot", "xcaliber-t20"], ["wait", 10],
        ["shot", "xcaliber-t30"]]},
    "talons": {"program": "::/Demo/Games/Talons.HC", "steps": [
        ["wait", 10], ["shot", "talons-t010"], ["wait", 20], ["shot", "talons-t030"], ["wait", 30],
        ["shot", "talons-t060"], ["wait", 60], ["shot", "talons-t120"], ["wait", 60], ["shot", "talons-t180"]]},
}


def blackbox(name, outdir, mem=1024, smp=2, steps=None, program=None):
    """Boots the ISO, waits until the shell takes keys (a readiness probe writes 'R' to the debug console),
    types "AutoComplete;WinMax;" as capture_catalog.py does, runs the program from the CD with #include and
    follows the scenario. The program file is the CD's, unmodified; nothing is loaded through fw_cfg."""
    import time
    from templeos_vm import TempleVM
    sc = SCENARIOS[name]
    os.makedirs(outdir, exist_ok=True)
    dbg = os.path.join(outdir, "probe.log")
    if os.path.exists(dbg):
        os.remove(dbg)
    vm = TempleVM(outdir, smp=smp, mem=mem, extra_args=("-accel", "tcg", "-cpu", "qemu64", "-chardev",
                  f"file,id=dbg0,path={dbg}", "-device", "isa-debugcon,iobase=0xe9,chardev=dbg0"))
    log = []
    t_start = time.time()
    try:
        time.sleep(20)
        for _ in range(2):
            vm.key("n")
            time.sleep(5)
        ready = False
        for probe in range(15):
            if probe:  # a live-CD question may still be waiting (a lost "n"): answer it; at the shell
                vm.key("n")  # the "n" only becomes a harmless undefined-identifier error line
            vm.type("\nOutU8(0xE9,82);OutU8(0xE9,10);\n", delay=0.04, hold_ms=40)
            time.sleep(3)
            if os.path.exists(dbg) and b"R" in open(dbg, "rb").read():
                ready = True
                break
        log.append({"t_boot": round(time.time() - t_start, 1), "shell_ready": ready})
        if not ready:
            vm.shot("not-ready")
            return log
        vm.type("AutoComplete;WinMax;\n", delay=0.04, hold_ms=40)
        time.sleep(2)
        vm.type(f'#include "{program or sc["program"]}";\n', delay=0.04, hold_ms=40)
        t0 = time.time()
        for st in steps or sc["steps"]:
            op = st[0]
            log.append({"t": round(time.time() - t0, 1), "step": st})
            if op == "wait":
                time.sleep(st[1])
            elif op == "shot":
                vm.shot(st[1])
            elif op == "key":
                vm.key(*st[1:])
            elif op == "hold":
                vm.key_down(st[1], True); time.sleep(st[2]); vm.key_down(st[1], False)
            elif op == "type":
                vm.type(st[1], delay=0.04, hold_ms=40)
            elif op == "cmd":
                vm.cmd(st[1], settle=st[2])
    finally:
        vm.quit()
        import templeos_harness as th
        meta = {"what": f"UNMODIFIED program {program or sc['program']} run from the CD by keyboard (black-box)",
                "typed_before_program": ["OutU8(0xE9,82);OutU8(0xE9,10);  (readiness probe, repeated until seen)",
                                         "AutoComplete;WinMax;  (as tools/reference-vm/capture_catalog.py)"],
                "date_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(timespec="seconds"),
                "iso_sha256": th.sha256(th.ISO), "qemu_version": th.qemu_version(), "qemu_args": vm.args,
                "guest": {"cpu": "qemu64", "smp": smp, "mem_mib": mem, "accelerator": "tcg (software x86-64 emulation)",
                          "icount": "none (real-time timers: screenshot times are host seconds)"},
                "host": {"os": __import__("platform").platform(), "machine": __import__("platform").machine()},
                "log": log}
        json.dump(meta, open(os.path.join(outdir, "run.json"), "w"), indent=1)
        for n in ("qemu.pid", "qmp.port", "qemu.log", "probe.log"):
            p = os.path.join(outdir, n)
            if os.path.exists(p) and n != "probe.log":
                os.remove(p)
    return log


def cmd_blackbox(a):
    names = a.only.split(",") if a.only else list(SCENARIOS)
    jobs = []
    for n in names:
        jobs.append((n, os.path.join(BLACKBOX, n), 1024, None, None))
    if "talons" in names and a.talons_mem:
        for m in a.talons_mem.split(","):
            jobs.append(("talons", os.path.join(BLACKBOX, f"talons-mem{m}"), int(m),
                         [["wait", 15], ["shot", "talons-t015"], ["wait", 45], ["shot", "talons-t060"],
                          ["wait", 60], ["shot", "talons-t120"]], None))
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(lambda j: (j[1], blackbox(j[0], j[1], mem=j[2], steps=j[3], program=j[4])), jobs):
            print("done", rel(r[0]), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("rng")
    p.add_argument("--reuse", action="store_true", help="re-parse the last run instead of booting the VM")
    sub.add_parser("cartesian-input")
    p = sub.add_parser("cartesian")
    p.add_argument("--jobs", type=int, default=3)
    p.add_argument("--only", default="")
    for n in ("talons", "xcaliber", "evalorder", "x87"):
        p = sub.add_parser(n)
        p.add_argument("--reuse", action="store_true")
    p = sub.add_parser("talons-mem")
    p.add_argument("--mem", default="128,160,192,256,512")
    p.add_argument("--seconds", type=int, default=150)
    p.add_argument("--jobs", type=int, default=3)
    p.add_argument("--reuse", action="store_true")
    p = sub.add_parser("compare")
    p.add_argument("appdir")
    p = sub.add_parser("blackbox")
    p.add_argument("--only", default="")
    p.add_argument("--talons-mem", default="128,192,256,512")
    p.add_argument("--jobs", type=int, default=3)
    a = ap.parse_args()
    {"rng": cmd_rng, "cartesian-input": cmd_cartesian_input, "cartesian": cmd_cartesian,
     "talons": cmd_talons, "xcaliber": cmd_xcaliber, "blackbox": cmd_blackbox, "compare": cmd_compare,
     "evalorder": cmd_evalorder, "talons-mem": cmd_talons_mem, "x87": cmd_x87}[a.cmd](a)


if __name__ == "__main__":
    main()
