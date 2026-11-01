#!/usr/bin/env python3
"""Drive an original TempleOS V5.03 in QEMU as a behavioural reference.

The VM boots the official, unmodified ISO (reference/iso/TempleOS.ISO, sha256 5d0fc944...)
from CD with no network device and no disk. It is scripted only through QEMU's QMP
socket: keys go in as PS/2 scan codes, the mouse as relative PS/2 movement, the
screen comes out as PNG screendumps and the PC speaker is recorded to a WAV file.

Development tool only (never shipped). See docs/fidelity-audit/README.md.

    python3 tools/reference-vm/templeos_vm.py boot            # boot to a shell and screenshot
    python3 tools/reference-vm/templeos_vm.py run SCRIPT.json OUT # run a JSON list of steps
    python3 tools/reference-vm/templeos_vm.py start DIR; ... key/type/cmd/click/shot DIR ...; stop DIR
    python3 tools/reference-vm/templeos_vm.py run-harness OUT --harness F.HC [...]   # fw_cfg in, debugcon out
                                       (templeos_harness.py; docs/native-validation/VM_HARNESS.md)
"""
import json
import os
import socket
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _find_iso():
    """reference/ is not versioned, so a separate worktree checkout has none: TEMPLEOS_ISO, else
    the first reference/iso/TempleOS.ISO found walking up from the repository (the main checkout)."""
    if os.environ.get("TEMPLEOS_ISO"):
        return os.environ["TEMPLEOS_ISO"]
    d = ROOT
    while True:
        p = os.path.join(d, "reference", "iso", "TempleOS.ISO")
        if os.path.exists(p):
            return p
        if os.path.dirname(d) == d:
            return os.path.join(ROOT, "reference", "iso", "TempleOS.ISO")
        d = os.path.dirname(d)


ISO = _find_iso()
ISO_SHA256 = "5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26"

# US-layout characters to QEMU qcodes (shifted characters marked with a leading '+').
_QC = {}
for c in "abcdefghijklmnopqrstuvwxyz":
    _QC[c] = c
    _QC[c.upper()] = "+" + c
for c in "0123456789":
    _QC[c] = c
_SHIFTED_DIGITS = ")!@#$%^&*("
for i, c in enumerate(_SHIFTED_DIGITS):
    _QC[c] = "+" + str(i)
_QC.update({
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "_": "+minus", "=": "equal", "+": "+equal",
    "[": "bracket_left", "{": "+bracket_left", "]": "bracket_right", "}": "+bracket_right",
    ";": "semicolon", ":": "+semicolon", "'": "apostrophe", '"': "+apostrophe",
    "`": "grave_accent", "~": "+grave_accent", "\\": "backslash", "|": "+backslash",
    ",": "comma", "<": "+comma", ".": "dot", ">": "+dot", "/": "slash", "?": "+slash",
})


class QMP:
    def __init__(self, port):
        for _ in range(100):
            try:
                self.s = socket.create_connection(("127.0.0.1", port))
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError(f"no QMP server on 127.0.0.1:{port}")
        self.f = self.s.makefile("rw")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args} if args else {"execute": name}) + "\n")
        self.f.flush()
        r = self._read()
        if "error" in r:
            raise RuntimeError(f"{name}: {r['error']}")
        return r.get("return")


class TempleVM:
    """One QEMU process running the TempleOS live CD."""

    def __init__(self, workdir, wav=None, smp=2, mem=1024, attach=False, extra_args=(), rtc="base=localtime"):
        """extra_args: more QEMU arguments, e.g. ("-icount", "shift=auto") so that TempleOS's timers
        (PIT jiffies, RTC with rtc="base=localtime,clock=vm") all run on QEMU's virtual clock and keep
        their relative rates under TCG (tools/audio/vm_semantics.py)."""
        os.makedirs(workdir, exist_ok=True)
        self.workdir = workdir
        # QMP on loopback TCP (UNIX socket paths are limited to 104 bytes on macOS). A free port is
        # picked per VM and saved in the work directory for later "attach" commands.
        port_file = os.path.join(workdir, "qmp.port")
        if attach:
            self.port = int(open(port_file).read())
        else:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                self.port = probe.getsockname()[1]
            open(port_file, "w").write(str(self.port))
        self.shots = 0
        self.t0 = time.time()
        if attach:  # a VM started earlier by "start" (one QMP client at a time)
            self.proc = None
            self.q = QMP(self.port)
            return
        audio = ["-audiodev", f"wav,id=snd0,path={wav}"] if wav else ["-audiodev", "none,id=snd0"]
        self.args = [
            "qemu-system-x86_64", "-m", str(mem), "-smp", str(smp),
            "-cdrom", ISO, "-boot", "d",
            "-nic", "none",                      # no network device at all
            "-display", "none", "-vga", "std",
            *audio, "-machine", "pc,pcspk-audiodev=snd0",
            "-qmp", f"tcp:127.0.0.1:{self.port},server,nowait",
            "-rtc", rtc,
            *extra_args,
        ]
        self.proc = subprocess.Popen(self.args, stdout=subprocess.DEVNULL, stderr=open(os.path.join(workdir, "qemu.log"), "w"),
                                     start_new_session=True)
        open(os.path.join(workdir, "qemu.pid"), "w").write(str(self.proc.pid))
        self.q = QMP(self.port)

    # ---------------------------------------------------------------- output

    def shot(self, name):
        path = os.path.join(self.workdir, name if name.endswith(".png") else name + ".png")
        self.q.cmd("screendump", filename=path, format="png")
        # screendump is asynchronous in recent QEMU: wait for the file
        for _ in range(200):  # up to 10 s: a busy TCG guest can delay the display update
            if os.path.exists(path) and os.path.getsize(path) > 0:
                break
            time.sleep(0.05)
        self.shots += 1
        return path

    # ---------------------------------------------------------------- keyboard

    def key(self, *qcodes, hold_ms=60):
        keys = [{"type": "qcode", "data": k} for k in qcodes]
        self.q.cmd("send-key", keys=keys, **{"hold-time": hold_ms})
        time.sleep(hold_ms / 1000 + 0.04)

    def key_down(self, qcode, down=True):
        self.q.cmd("input-send-event", events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}])

    def type(self, text, delay=0.03, hold_ms=40):
        for ch in text:
            qc = _QC.get(ch)
            if qc is None:
                raise ValueError(f"cannot type {ch!r}")
            if qc.startswith("+"):
                self.key("shift", qc[1:], hold_ms=hold_ms)
            else:
                self.key(qc, hold_ms=hold_ms)
            time.sleep(delay)

    # ---------------------------------------------------------------- mouse (PS/2, relative)

    def mouse_rel(self, dx, dy):
        ev = []
        if dx:
            ev.append({"type": "rel", "data": {"axis": "x", "value": int(dx)}})
        if dy:
            ev.append({"type": "rel", "data": {"axis": "y", "value": int(dy)}})
        if ev:
            self.q.cmd("input-send-event", events=ev)
            time.sleep(0.02)

    def mouse_home(self):
        """Pin the pointer to the top-left corner (TempleOS clamps it to the screen)."""
        for _ in range(12):
            self.mouse_rel(-200, -200)
        self.mx, self.my = 0, 0

    def mouse_to(self, x, y, scale=0.5):
        """Moves to screen pixel (x, y). TempleOS scales PS/2 counts by ms_hard.scale (0.5 in
        HomeLocalize.HC), so one count is half a pixel; moves are split into small steps."""
        if not hasattr(self, "mx"):
            self.mouse_home()
        dx, dy = (x - self.mx) / scale, (y - self.my) / scale
        steps = max(1, int(max(abs(dx), abs(dy)) // 60) + 1)
        for i in range(steps):
            self.mouse_rel(dx / steps, dy / steps)
        self.mx, self.my = x, y

    def button(self, btn="left", down=True):
        self.q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": btn}}])
        time.sleep(0.03)

    def click(self, x=None, y=None, btn="left", hold=0.08):
        if x is not None:
            self.mouse_to(x, y)
        self.button(btn, True)
        time.sleep(hold)
        self.button(btn, False)

    # ---------------------------------------------------------------- lifecycle

    def boot_to_shell(self, timeout=240):
        """Answers the live CD's two questions with 'n' (Once.HC: install? take tour?)."""
        time.sleep(8)
        deadline = time.time() + timeout
        # Wait for the install prompt: poll screenshots for a non-blank screen, then keep
        # answering 'n' until the tour question has been passed.
        answered = 0
        while time.time() < deadline and answered < 2:
            time.sleep(6)
            self.key("n")
            answered += 1
        time.sleep(4)
        return self.shot("boot")

    def cmd(self, line, settle=1.0):
        """Types a HolyC command line in the focused terminal and presses ENTER."""
        self.type(line)
        self.key("ret")
        time.sleep(settle)

    def detach(self):
        self.q.s.close()

    def quit(self):
        try:
            self.q.cmd("quit")
        except Exception:
            pass
        try:
            if self.proc:
                self.proc.wait(10)
        except Exception:
            self.proc.kill()


def run_script(path, outdir):
    """Runs a scenario: {"program": "::/Demo/Games/X.HC", "steps": [...]}.

    Steps: ["wait", s] ["shot", name] ["key", qcode...] ["hold", qcode, s] ["type", text]
           ["cmd", line] ["click", x, y, "left"|"right"] ["drag", x0, y0, x1, y1]
    """
    sc = json.load(open(path))
    vm = TempleVM(outdir, wav=os.path.join(outdir, "speaker.wav") if sc.get("audio") else None)
    log = []
    try:
        vm.boot_to_shell()
        if sc.get("program"):
            vm.cmd(f'#include "{sc["program"]}";', settle=sc.get("settle", 3))
        for st in sc.get("steps", []):
            op = st[0]
            log.append({"t": round(time.time() - vm.t0, 2), "step": st})
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
            elif op == "cmd":
                vm.cmd(st[1], settle=st[2] if len(st) > 2 else 1.0)
            elif op == "click":
                vm.click(st[1], st[2], st[3] if len(st) > 3 else "left")
            elif op == "move":
                vm.mouse_to(st[1], st[2])
            elif op == "drag":
                vm.mouse_to(st[1], st[2]); vm.button("left", True)
                vm.mouse_to(st[3], st[4]); vm.button("left", False)
            else:
                raise ValueError(op)
    finally:
        vm.quit()
        json.dump(log, open(os.path.join(outdir, "log.json"), "w"), indent=1)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    if sys.argv[1] == "boot":
        out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/templeos-vm"
        vm = TempleVM(out)
        try:
            print(vm.boot_to_shell())
        finally:
            vm.quit()
    elif sys.argv[1] == "run":
        run_script(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "run-harness":  # boot, load harness file(s) over fw_cfg, collect debugcon output
        import templeos_harness
        sys.argv = [sys.argv[0], "run"] + sys.argv[2:]
        return templeos_harness.main()
    elif sys.argv[1] == "start":   # start DIR [wav]: leave a VM running for interactive steps
        vm = TempleVM(sys.argv[2], wav=sys.argv[3] if len(sys.argv) > 3 else None)
        vm.detach()
    elif sys.argv[1] in ("shot", "type", "cmd", "key", "hold", "click", "rclick", "move", "drag", "stop", "down", "up"):
        vm = TempleVM(sys.argv[2], attach=True)
        a = sys.argv[3:]
        op = sys.argv[1]
        if op == "shot": print(vm.shot(a[0]))
        elif op == "type": vm.type(a[0].encode().decode("unicode_escape"))
        elif op == "cmd": vm.cmd(a[0], settle=float(a[1]) if len(a) > 1 else 1.0)
        elif op == "key": vm.key(*a)
        elif op == "hold": vm.key_down(a[0], True); time.sleep(float(a[1])); vm.key_down(a[0], False)
        elif op == "down": vm.key_down(a[0], True)
        elif op == "up": vm.key_down(a[0], False)
        elif op in ("click", "rclick"):
            st = os.path.join(sys.argv[2], "mouse.json")
            if os.path.exists(st): vm.mx, vm.my = json.load(open(st))
            vm.click(int(a[0]), int(a[1]), "right" if op == "rclick" else "left")
            json.dump([vm.mx, vm.my], open(st, "w"))
        elif op == "move":
            st = os.path.join(sys.argv[2], "mouse.json")
            if a[0] == "home": vm.mouse_home()
            else:
                if os.path.exists(st): vm.mx, vm.my = json.load(open(st))
                vm.mouse_to(int(a[0]), int(a[1]))
            json.dump([vm.mx, vm.my], open(st, "w"))
        elif op == "drag":
            st = os.path.join(sys.argv[2], "mouse.json")
            if os.path.exists(st): vm.mx, vm.my = json.load(open(st))
            vm.mouse_to(int(a[0]), int(a[1])); vm.button("left", True)
            vm.mouse_to(int(a[2]), int(a[3])); vm.button("left", False)
            json.dump([vm.mx, vm.my], open(st, "w"))
        elif op == "stop": vm.quit(); return 0
        vm.detach()
    return 0


if __name__ == "__main__":
    sys.exit(main())
