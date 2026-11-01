#!/usr/bin/env python3
"""Store-readiness smoke test of the Android *release* build (com.digitalcircuitstudios.templeosapp), like a reviewer.

Drives the app only through its accessibility tree and adb input (no test hooks: release builds ignore the
automation intent extras). Wipes the app's data first (pm clear) for a true first launch, so never point it
at a personal phone without backing the app's data up.

  android_release_smoke.py -s SERIAL --apk app-release.apk --out DIR [--programs all|none|Name,Name]
      [--package com.digitalcircuitstudios.templeosapp.bench] [--no-rotate]

On a personal phone use --package com.digitalcircuitstudios.templeosapp.bench (the side-by-side bench build, `assembleBench`)
so the owner's own app and its data are never touched, and --no-rotate (never change the phone's global
rotation settings; ColorOS refuses them anyway).

Writes DIR/result.json (every step with pass/fail and the evidence it saw) and DIR/*.png.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/performance-analysis"))
import android_ui  # noqa: E402

PKG = android_ui.PKG
NAMES = {' ': 'Space', '\n': 'Enter', '"': 'quote', "'": 'apostrophe', ';': 'semicolon', ':': 'colon', ',': 'comma',
         '.': 'period', '(': 'left parenthesis', ')': 'right parenthesis', '{': 'left brace', '}': 'right brace',
         '[': 'left bracket', ']': 'right bracket', '<': 'less than', '>': 'greater than', '=': 'equals', '+': 'plus',
         '-': 'minus', '_': 'underscore', '/': 'slash', '\\': 'backslash', '*': 'asterisk', '!': 'exclamation mark',
         '%': 'percent', '&': 'ampersand', '#': 'number sign'}


class Smoke:
    def __init__(self, d, out, rotate_ok=True):
        self.d, self.out, self.steps, self.rotate_ok = d, out, [], rotate_ok
        self.since = d.shell("date +%s").strip() + ".0"
        self.apk = None

    # ------------------------------------------------------------ helpers
    def pid(self):
        return self.d.shell("pidof " + PKG, check=False).strip()

    def labels(self):
        return [n["label"] for n in self.d.nodes()]

    def wait_label(self, frag, timeout=25.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if any(frag in l for l in self.labels()):
                return True
            time.sleep(0.4)
        return False

    def step(self, name, ok, **evidence):
        self.d.shot(str(self.out / (name + ".png")))
        rec = {"step": name, "pass": bool(ok), "pid": self.pid(), **evidence}
        self.steps.append(rec)
        print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:300], flush=True)
        return ok

    def type_keys(self, text):
        cache = {n["label"]: n for n in self.d.nodes()}

        def press(label):
            nonlocal cache
            if label not in cache:
                cache = {n["label"]: n for n in self.d.nodes()}
            x0, y0, x1, y1 = cache[label]["bounds"]
            self.d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        for ch in text:
            label = NAMES.get(ch, ch)
            shifted = False
            if label not in cache:
                cache = {n["label"]: n for n in self.d.nodes()}
            if label not in cache and "Letters" in cache:
                press("Letters"); cache = {n["label"]: n for n in self.d.nodes()}
            if label not in cache and ch.isalpha():
                press("Shift"); shifted = True; cache = {n["label"]: n for n in self.d.nodes()}
            if label not in cache and not ch.isalpha() and "Symbols" in cache:
                press("Symbols"); cache = {n["label"]: n for n in self.d.nodes()}
            press(label)
            if shifted:
                cache = {n["label"]: n for n in self.d.nodes()}

    def answer_modal(self):
        """A program's TempleOS choice dialog (e.g. RocketScience's PopUp) exposes only its rows: pick the middle
        one, as a user would (Android Back does not cancel these dialogs)."""
        nodes = self.d.nodes()
        if any(n["label"] == "MENU" for n in nodes):
            return None
        rows = nodes[1:] if len(nodes) > 1 else nodes
        if not rows:
            self.d.key("KEYCODE_BACK"); time.sleep(1); return "back"
        n = rows[len(rows) // 2]
        x0, y0, x1, y1 = n["bounds"]; self.d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2); time.sleep(2)
        return [m["label"].strip()[:40] for m in nodes][:8]

    def start(self, item):
        self.d.tap("MENU", timeout=12); self.d.tap(item, timeout=12); time.sleep(2)

    def close_window(self, title):
        for n in self.d.nodes():
            if n["label"].startswith("Close " + title):
                x0, y0, x1, y1 = n["bounds"]; self.d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2); time.sleep(1.2)
                return True
        return False

    def crashes(self):
        # never clear the device's log buffers (a personal phone's other apps): read from this run's start time
        log = self.d.adb("logcat", "-d", "-b", "crash", "-T", self.since, check=False, timeout=60)
        return [l for l in log.splitlines() if PKG in l or "FATAL EXCEPTION" in l]

    def pss_kb(self):
        m = re.search(r"TOTAL PSS:\s+(\d+)", self.d.shell("dumpsys meminfo " + PKG, check=False))
        if not m:
            m = re.search(r"TOTAL\s+(\d+)", self.d.shell("dumpsys meminfo " + PKG, check=False))
        return int(m.group(1)) if m else None

    # ------------------------------------------------------------ flows
    def core_flow(self):
        d = self.d
        d.shell("input keyevent KEYCODE_WAKEUP")
        d.shell("am force-stop " + PKG)
        try:
            d.shell("pm clear " + PKG)
        except RuntimeError:  # ColorOS refuses pm clear from adb: a fresh install of the same package instead
            if not self.apk:
                raise
            d.adb("uninstall", PKG, check=False); d.install(self.apk)
        t = d.shell("am start -W -n " + android_ui.ACT)
        cold = re.search(r"TotalTime: (\d+)", t)
        time.sleep(3)
        self.step("01-first-launch-welcome", self.wait_label("Welcome.DD"), cold_start_ms=int(cold.group(1)) if cold else None)
        self.start("Terminal")
        self.step("02-terminal-keyboard", self.wait_label("Terminal") and "Hide keyboard" in self.labels())
        self.type_keys("6*7;\n")
        self.step("03-valid-holyc", self.wait_label("=42"))
        self.type_keys("I64 x=;\n")
        self.step("04-invalid-holyc-error", self.wait_label("unexpected"))  # e.g. Cmd.HC:1: unexpected ';'
        self.type_keys("while (1) {}\n"); time.sleep(2)
        busy = self.pid()
        broke = False
        try:  # the window menu's Break (Ctrl-C), as a user would
            d.tap("Window menu: Terminal", timeout=6); d.tap("Break (Ctrl-C)", timeout=6); broke = True
        except Exception as e:
            print("break via menu failed:", e)
        time.sleep(2)
        self.type_keys("1+1;\n")
        self.step("05-interrupt-and-recover", broke and self.wait_label("=2") and self.pid() == busy)
        self.close_window("Terminal")
        # Editor: write, save, run
        self.start("HolyC Editor")
        self.type_keys('"Saved OK\\n";')
        d.tap("SAVE", timeout=8)
        bs = next((n for n in d.nodes() if n["label"] == "Backspace"), None)
        if bs:
            x0, y0, x1, y1 = bs["bounds"]
            for _ in range(40):
                d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        self.type_keys("C:/Home/Review.HC\n")
        if "REPLACE" in self.labels():
            d.tap("REPLACE")
        saved = self.wait_label("Review.HC", 8)
        d.tap("RUN", timeout=8)
        self.step("06-editor-save-run", saved and self.wait_label("Saved OK"))
        # background / foreground keeps the windows
        def windows():
            labels = self.labels()
            more = next((int(l.split(":")[1]) for l in labels if l.startswith("More windows:")), 0)
            focused = next((l for l in labels if l.startswith("Window: ")), "")
            return focused, more
        before = windows()
        d.key("KEYCODE_HOME"); time.sleep(3)
        d.shell("am start -n " + android_ui.ACT); time.sleep(3)
        time.sleep(2); after = windows()
        self.step("07-background-foreground", after == before and "Review" in before[0], before=before, after=after)
        # process death + relaunch: session and file restored
        d.key("KEYCODE_HOME"); time.sleep(2)
        d.shell("am kill " + PKG); d.shell("am force-stop " + PKG); time.sleep(1)
        t = d.shell("am start -W -n " + android_ui.ACT)
        warm = re.search(r"TotalTime: (\d+)", t); time.sleep(3)
        self.wait_label("Window: ", 12); time.sleep(2); after = windows()
        self.step("08-relaunch-restores-session", after == before, before=before, after=after, relaunch_ms=int(warm.group(1)) if warm else None)
        # rotation (emulator only: personal phones keep their own settings)
        if self.rotate_ok:
            rot = d.rotate(True); time.sleep(3)
            self.step("09-landscape", rot and bool(self.labels()), size=d.shell("wm size").strip())
            d.rotate(False); time.sleep(3)
            self.step("10-portrait-again", bool(self.labels()))
            d.shell("settings put system accelerometer_rotation 1", check=False)
        self.step("11-no-crash-so-far", not self.crashes(), crash_log=self.crashes()[:5], pss_kb=self.pss_kb())

    def program_sweep(self, wanted):
        d = self.d
        cat = json.loads((ROOT / "shared/program-manifests/catalog.json").read_text())["programs"]
        menus = {"game": "Games...", "demo": "Demos...", "example": "Examples..."}
        progs = [p for p in cat if p["category"] in menus and p["status"] != "unsupported"]
        if wanted != "all":
            names = set(wanted.split(","))
            progs = [p for p in progs if p["title"] in names]
        results = []
        if self.rotate_ok:
            d.shell("settings put system accelerometer_rotation 0", check=False)
            d.shell("settings put system user_rotation 0", check=False)
        for p in progs:
            title = p["title"]
            pid0 = self.pid()
            rec = {"id": p["id"], "title": title, "status": p["status"]}
            try:
                for _ in range(4):  # a modal (a program's PopUp choice, a dialog) hides everything else
                    if self.answer_modal() is None:
                        break
                d.tap("MENU", timeout=12); d.tap(menus[p["category"]], timeout=12)
                found = None
                for _ in range(16):  # one accessibility dump per scroll step
                    nodes = d.nodes()
                    found = next((n for n in nodes if n["label"] == title or n["label"].startswith(title + " (")), None)
                    scroll = next((n for n in nodes if n["label"] == "Scroll menu down"), None)
                    if found or not scroll:
                        break
                    x0, y0, x1, y1 = scroll["bounds"]; d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2); time.sleep(0.3)
                if not found:
                    rec["error"] = "not in menu"; results.append(rec); d.key("KEYCODE_BACK"); continue
                x0, y0, x1, y1 = found["bounds"]; d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
                time.sleep(7)
                for _ in range(3):
                    if "OKAY" in self.labels():
                        d.tap("OKAY")
                d.key("KEYCODE_DPAD_UP"); d.key("KEYCODE_SPACE"); time.sleep(2)
                labels = self.labels()
                for _ in range(4):  # the program opened modal choices (e.g. RocketScience's PopUps): answer them
                    if "MENU" in labels:
                        break
                    d.shot(str(self.out / ("prog-" + re.sub(r"[^A-Za-z0-9]+", "_", title) + "-modal.png")))
                    rec.setdefault("modal", []).append(self.answer_modal()); time.sleep(2); labels = self.labels()
                text = "\n".join(labels)
                rec["window"] = any(l.startswith("Close " + title) for l in labels)
                rec["ended"] = (title + " (ended)") in text or "Ended:" in text
                rec["internal_error"] = "internal error" in text.lower() or "Internal error" in text
                rec["pss_kb"] = self.pss_kb()
                d.shot(str(self.out / ("prog-" + re.sub(r"[^A-Za-z0-9]+", "_", title) + ".png")))
                rec["closed"] = self.close_window(title)
                time.sleep(1)
                rec["alive"] = self.pid() == pid0 and bool(pid0)
            except Exception as e:  # keep going: record the failure
                rec["error"] = str(e)[:200]
                d.key("KEYCODE_BACK")
            rec["pass"] = bool(rec.get("window") and rec.get("alive") and not rec.get("internal_error") and "error" not in rec)
            print(("PASS " if rec["pass"] else "FAIL ") + json.dumps(rec), flush=True)
            results.append(rec)
        if self.rotate_ok:
            d.shell("settings put system accelerometer_rotation 1", check=False)
        return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk")
    ap.add_argument("--out", required=True)
    ap.add_argument("--programs", default="all")
    ap.add_argument("--skip-core", action="store_true")
    ap.add_argument("--package", default="com.digitalcircuitstudios.templeosapp")
    ap.add_argument("--no-rotate", action="store_true")
    a = ap.parse_args()
    global PKG
    PKG = android_ui.PKG = a.package
    android_ui.ACT = a.package + "/io.github.templeosmobile.android.MainActivity"
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    d = android_ui.Device(a.serial)
    if a.apk:
        d.install(a.apk)
    s = Smoke(d, out, rotate_ok=not a.no_rotate)
    s.apk = a.apk
    device = {k: d.shell("getprop " + p).strip() for k, p in [("model", "ro.product.model"), ("manufacturer", "ro.product.manufacturer"),
              ("release", "ro.build.version.release"), ("sdk", "ro.build.version.sdk"), ("abi", "ro.product.cpu.abi")]}
    device["size"] = d.shell("wm size").strip(); device["density"] = d.shell("wm density").strip()
    pkg = d.shell("dumpsys package " + PKG + " | grep -E 'versionName|versionCode|flags=' | head -4", check=False)
    report = {"device": device, "package": pkg.strip(), "steps": [], "programs": []}
    try:
        if not a.skip_core:
            s.core_flow()
        if a.programs != "none":
            report["programs"] = s.program_sweep(a.programs)
    finally:
        report["steps"] = s.steps
        report["crash_log"] = s.crashes()[:20]
        (out / "result.json").write_text(json.dumps(report, indent=1))
    progs = report["programs"]
    print("steps %d/%d pass; programs %d/%d pass; crash lines %d" % (
        sum(x["pass"] for x in s.steps), len(s.steps), sum(p["pass"] for p in progs), len(progs), len(report["crash_log"])))


if __name__ == "__main__":
    main()
