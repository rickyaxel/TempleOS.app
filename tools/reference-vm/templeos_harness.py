#!/usr/bin/env python3
"""Fast, exact I/O channels into and out of the original TempleOS V5.03 (reference VM).

Typing programs through the emulated PS/2 keyboard is slow (about 0.1 s per character) and the only
way out used to be screendumps. This module adds two channels that need no change to the ISO:

OUTPUT  QEMU's ISA debug console. Two isa-debugcon devices are attached, each to a host file:
          port 0xE9 -> harness.log   structured lines written by the harness (HPrint, OutU8/RepOutU8)
          port 0xEA -> console.log   a raw copy of everything the harness task prints, taken from a
                                     hook in TempleOS's own StdOut chain (KeyDevAdd), so compiler
                                     errors and Print output are captured too
        TempleOS runs all code in ring 0, so a HolyC program may execute OUT to any port. A debugcon
        port write is one byte to the host file, unbuffered and unaltered (no newline translation).
INPUT   QEMU fw_cfg. Host files are attached as -fw_cfg name=opt/templeos/<name>,file=<path>. The guest
        reads them through the fw_cfg I/O ports (selector 0x510 16-bit, data 0x511 byte-wise; the file
        directory is item 0x19 with big-endian entries). A 330-character stage-0 loader (STAGE0) is
        the only text typed through the keyboard: it reads opt/templeos/boot (harness/VmIO.HC) and runs
        it with ExePutS, the routine TempleOS itself uses for #include/ExeFile/ExePrint. VmIO.HC then
        runs opt/templeos/h0, h1, ... (the harness files) one after another with ExePutS, each inside
        try/catch, and reports LOADER begin/end/except/compile-error lines with the FNV-1a 64 of the
        bytes it received. Data files are opt/templeos/d/<name> (HData("name") in HolyC).

A heartbeat task on CPU 1 prints "HB <jiffies> <progress> <dbg_mode>" every second; the host stops a
run when the harness prints HARNESS-DONE, when the overall timeout passes, when nothing (not even a
heartbeat) arrives for --silence seconds, or when the heartbeat reports the TempleOS debugger. A
screendump is saved at the end of every run (final.png) so a hang or a debugger screen is visible.

CPU: QEMU on this Apple Silicon host has no x86 hardware virtualization; the guest x86-64 CPU (qemu64)
is emulated by TCG (dynamic binary translation; `qemu-system-x86_64 -accel help` lists only tcg). x87
and SSE arithmetic are emulated in software (softfloat), including the x87's 80-bit extended format.
With --icount (e.g. shift=auto, the default for run-harness) TempleOS's timers (PIT jiffies, HPET,
TSC, RTC on clock=vm) all advance with the instruction count, as in tools/audio/vm_semantics.py.

Every run writes meta.json next to its results: ISO sha256, QEMU version, the full QEMU command line,
guest CPU/smp/memory, accelerator, icount, host OS/arch, date, and the sha256 of every harness and
data file.

    python3 tools/reference-vm/templeos_harness.py run OUTDIR --harness FILE.HC [--harness ...]
            [--data NAME=PATH ...] [--timeout S] [--silence S] [--mem MB] [--smp N] [--icount shift=auto|none]
    python3 tools/reference-vm/templeos_harness.py roundtrip OUTDIR      # byte-exactness proof

Development tool only (QEMU, no network, no disk, official ISO). See docs/native-validation/VM_HARNESS.md.
"""
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from templeos_vm import ISO, ISO_SHA256, ROOT, TempleVM  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
VMIO = os.path.join(HERE, "harness", "VmIO.HC")


def portable(s):
    """Paths recorded in meta.json: repo-relative, else home-relative, so no user or machine names leak."""
    s = s.replace(ROOT + os.sep, "")
    home = os.path.expanduser("~")
    return s.replace(home + os.sep, "~" + os.sep) if home not in ("", os.sep) else s

# The only text typed through the keyboard (after "AutoComplete;"). Reads fw_cfg file opt/templeos/boot
# into a CAlloc'd buffer (zero-terminated) and compiles+runs it with ExePutS.
STAGE0 = ('I64 Fb(I64 k){I64 r=0;while(k--)r=r<<8|InU8(0x511);return r;}'
          'U8 *FwLd(U8 *nm){I64 n,s,k;U8 e[56],*b;OutU16(0x510,0x19);n=Fb(4);'
          'while(n--){s=Fb(4);k=Fb(2);Fb(2);RepInU8(e,56,0x511);'
          'if(!StrCmp(e,nm)){b=CAlloc(s+1);OutU16(0x510,k);RepInU8(b,s,0x511);return b;}}return NULL;}'
          'ExePutS(FwLd("opt/templeos/boot"),"VmIO.HC");')


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fnv1a64(data):
    h = 0xCBF29CE484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def qemu_version():
    return subprocess.run(["qemu-system-x86_64", "--version"], capture_output=True, text=True).stdout.strip()


def parse_stream(data):
    """Splits the port-0xE9 stream into text lines and BLOBs ("BLOB name len\\n" + len raw bytes + "\\nEND-BLOB\\n")."""
    lines, blobs, i = [], {}, 0
    while i < len(data):
        j = data.find(b"\n", i)
        if j < 0:
            lines.append(data[i:].decode("latin-1"))
            break
        line = data[i:j].decode("latin-1")
        i = j + 1
        m = re.match(r"BLOB (\S+) (\d+)$", line)
        if m:
            n = int(m.group(2))
            blobs[m.group(1)] = data[i:i + n]
            i += n
            if data[i:i + 10] == b"\nEND-BLOB\n":
                i += 10
            continue
        lines.append(line)
    return lines, blobs


class HarnessRun:
    def __init__(self, outdir, harnesses, data=(), mem=1024, smp=2, icount="shift=auto", timeout=900,
                 silence=60, shots=(), boot_wait=20, typing=(25, 0.02)):
        self.out = os.path.abspath(outdir)
        os.makedirs(self.out, exist_ok=True)
        self.harnesses = [os.path.abspath(h) for h in harnesses]
        self.data = [(n, os.path.abspath(p)) for n, p in data]
        self.mem, self.smp, self.icount = mem, smp, icount
        self.timeout, self.silence, self.shots, self.boot_wait = timeout, silence, list(shots), boot_wait
        self.typing = typing
        self.log_path = os.path.join(self.out, "harness.log")
        self.con_path = os.path.join(self.out, "console.log")

    def qemu_extra(self):
        a = ["-accel", "tcg", "-cpu", "qemu64",
             "-chardev", f"file,id=dbg0,path={self.log_path}", "-device", "isa-debugcon,iobase=0xe9,chardev=dbg0",
             "-chardev", f"file,id=dbg1,path={self.con_path}", "-device", "isa-debugcon,iobase=0xea,chardev=dbg1",
             "-fw_cfg", f"name=opt/templeos/boot,file={VMIO}"]
        for i, h in enumerate(self.harnesses):
            a += ["-fw_cfg", f"name=opt/templeos/h{i},file={h}"]
        for n, p in self.data:
            a += ["-fw_cfg", f"name=opt/templeos/d/{n},file={p}"]
        if self.icount and self.icount != "none":
            a += ["-icount", self.icount]
        for x in a:
            if "," in x and ("file=" in x or "path=" in x) and ",," in x:
                raise ValueError("paths with commas are not supported")
        return a

    def meta(self, vm, result):
        files = {"boot (VmIO.HC)": {"path": os.path.relpath(VMIO, ROOT), "sha256": sha256(VMIO)}}
        for i, h in enumerate(self.harnesses):
            files[f"h{i}"] = {"path": portable(h), "sha256": sha256(h),
                              "fnv1a64": f"{fnv1a64(open(h, 'rb').read()):016X}"}
        for n, p in self.data:
            files[f"d/{n}"] = {"path": portable(p), "sha256": sha256(p)}
        u = os.uname()
        return {
            "tool": "tools/reference-vm/templeos_harness.py",
            "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "iso": {"path": portable(ISO), "sha256": sha256(ISO), "expected_sha256": ISO_SHA256},
            "qemu_version": qemu_version(),
            "qemu_args": [portable(a) for a in vm.args],
            "guest": {"machine": "pc", "cpu": "qemu64", "smp": self.smp, "mem_mib": self.mem,
                      "accelerator": "tcg (software emulation of x86-64; no hardware virtualization on this host)",
                      "icount": self.icount, "rtc": vm.rtc, "network": "none", "disk": "none (live CD only)"},
            # uname without the node (host) name
            "host": {"os": platform.platform(), "machine": platform.machine(),
                     "uname": " ".join((u.sysname, u.release, u.version, u.machine)),
                     "python": platform.python_version()},
            "stage0_typed": "AutoComplete;\\n" + STAGE0 + "\\n",
            "files": files,
            "result": result,
        }

    def _read(self):
        try:
            with open(self.log_path, "rb") as f:
                return f.read()
        except FileNotFoundError:
            return b""

    def run(self):
        if sha256(ISO) != ISO_SHA256:
            raise SystemExit(f"ISO sha256 mismatch: {ISO}")
        for p in (self.log_path, self.con_path):
            if os.path.exists(p):
                os.remove(p)
        rtc = "base=localtime,clock=vm" if self.icount and self.icount != "none" else "base=localtime"
        vm = TempleVM(self.out, smp=self.smp, mem=self.mem, extra_args=self.qemu_extra(), rtc=rtc)
        vm.rtc = rtc
        result = {"status": "?"}
        t_start = time.time()
        events = []
        try:
            time.sleep(self.boot_wait)
            for _ in range(2):              # the live CD's install and tour questions (Once.HC)
                vm.key("n")
                time.sleep(5)
            # Readiness probe: keys typed while the shell is still starting are lost, so a short command
            # that writes 'R' to port 0xE9 is typed until the 'R' arrives (a lost key only costs a retry).
            for probe in range(12):
                if probe:  # a live-CD question may still be waiting (a lost "n"): answer it; at the shell
                    vm.key("n")  # the "n" only becomes a harmless undefined-identifier error line
                vm.type("\nOutU8(0xE9,82);OutU8(0xE9,10);\n", delay=0.04, hold_ms=40)
                time.sleep(3)
                if b"R" in self._read():
                    events.append({"t": round(time.time() - t_start, 1), "event": f"shell ready (probe {probe + 1})"})
                    break
            booted = False
            for attempt, (hold, gap) in enumerate([self.typing, (40, 0.04), (60, 0.08)]):
                vm.type("AutoComplete;\n", delay=gap, hold_ms=hold)
                time.sleep(1.5)
                vm.type(STAGE0, delay=gap, hold_ms=hold)
                vm.key("ret")
                t0 = time.time()
                while time.time() - t0 < 30:
                    if b"BOOT-OK" in self._read():
                        booted = True
                        break
                    time.sleep(0.5)
                if booted:
                    events.append({"t": round(time.time() - t_start, 1), "event": f"boot-ok (typing attempt {attempt + 1}, hold {hold} ms)"})
                    break
                vm.shot(f"stage0-fail-{attempt + 1}")
                events.append({"t": round(time.time() - t_start, 1), "event": f"stage0 attempt {attempt + 1} failed"})
            if not booted:
                result = {"status": "boot-failed"}
                return result
            t_boot = time.time()
            last_size, last_change = 0, time.time()
            shots = sorted(self.shots)
            status = None
            while status is None:
                time.sleep(0.5)
                data = self._read()
                now = time.time()
                if len(data) != last_size:
                    last_size, last_change = len(data), now
                while shots and now - t_boot >= shots[0]:
                    vm.shot(f"t{int(shots.pop(0))}")
                if b"HARNESS-DONE" in data:
                    status = "done"
                elif now - t_boot > self.timeout:
                    status = "timeout"
                elif now - last_change > self.silence:
                    status = "silent"
                else:
                    hb = re.findall(rb"HB (\d+) (-?\d+) (\d+)\n", data[-400:])
                    if hb and hb[-1][2] != b"0":
                        time.sleep(3)
                        status = "debugger"
            result = {"status": status, "seconds_after_boot": round(time.time() - t_boot, 1),
                      "seconds_total": round(time.time() - t_start, 1)}
            vm.shot("final")
            return result
        finally:
            result["events"] = events
            vm.quit()
            data = self._read()
            lines, blobs = parse_stream(data)
            self.lines, self.blobs = lines, blobs
            result["loader"] = [l for l in lines if l.startswith(("LOADER", "BOOT-OK", "HARNESS-DONE"))]
            for i, h in enumerate(self.harnesses):
                exp = f"{fnv1a64(open(h, 'rb').read()):016X}"
                got = [l for l in lines if l.startswith(f"LOADER begin opt/templeos/h{i} ")]
                result.setdefault("harness_bytes_exact", {})[f"h{i}"] = bool(got) and got[0].endswith("fnv=" + exp)
            json.dump(self.meta(vm, result), open(os.path.join(self.out, "meta.json"), "w"), indent=1)


def roundtrip(outdir):
    """Byte-exactness proof: 1 MiB of every byte value goes in over fw_cfg and comes back over debugcon."""
    out = os.path.abspath(outdir)
    os.makedirs(out, exist_ok=True)
    import random
    rnd = random.Random(20261020)
    payload = bytes(range(256)) * 16 + bytes(rnd.getrandbits(8) for _ in range((1 << 20) - 4096))
    pin = os.path.join(out, "rt.bin")
    open(pin, "wb").write(payload)
    r = HarnessRun(out, [os.path.join(HERE, "harness", "RoundTrip.HC")], data=[("rt.bin", pin)], timeout=600)
    res = r.run()
    got = r.blobs.get("rt.bin", b"")
    line = next((l for l in r.lines if l.startswith("RT ")), "")
    summary = {
        "status": res["status"],
        "sent_bytes": len(payload), "sent_sha256": hashlib.sha256(payload).hexdigest(),
        "sent_fnv1a64": f"{fnv1a64(payload):016X}",
        "guest_report": line,
        "echoed_bytes": len(got), "echoed_sha256": hashlib.sha256(got).hexdigest(),
        "echo_identical": got == payload,
        "guest_fnv_matches": line.endswith(f"fnv={fnv1a64(payload):016X}"),
        "harness_bytes_exact": res.get("harness_bytes_exact"),
    }
    json.dump(summary, open(os.path.join(out, "roundtrip.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("outdir")
    r.add_argument("--harness", action="append", required=True)
    r.add_argument("--data", action="append", default=[], help="NAME=PATH, read in HolyC with HData(\"NAME\")")
    r.add_argument("--timeout", type=float, default=900)
    r.add_argument("--silence", type=float, default=60)
    r.add_argument("--mem", type=int, default=1024)
    r.add_argument("--smp", type=int, default=2)
    r.add_argument("--icount", default="shift=auto", help="QEMU -icount value, or 'none'")
    r.add_argument("--shot", type=float, action="append", default=[], help="screendump N s after boot")
    t = sub.add_parser("roundtrip")
    t.add_argument("outdir")
    a = ap.parse_args()
    if a.cmd == "run":
        data = [tuple(d.split("=", 1)) for d in a.data]
        h = HarnessRun(a.outdir, a.harness, data, mem=a.mem, smp=a.smp, icount=a.icount, timeout=a.timeout,
                       silence=a.silence, shots=a.shot)
        res = h.run()
        print(json.dumps(res, indent=1))
        return 0 if res["status"] == "done" else 1
    if a.cmd == "roundtrip":
        return 0 if roundtrip(a.outdir)["echo_identical"] else 1


if __name__ == "__main__":
    sys.exit(main())
