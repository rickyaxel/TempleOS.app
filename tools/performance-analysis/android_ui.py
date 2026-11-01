#!/usr/bin/env python3
"""Drives the Android app through its accessibility tree (uiautomator dump), like a user.

The desktop is one custom view; its buttons, rows and keys are virtual accessibility nodes
(AccessibilityAdapter), so every tap below also checks that the node exists and acts.

Library use (perf_android.py, menu_android.py) or command line:
  android_ui.py -s emulator-5554 tap "MENU"
  android_ui.py -s emulator-5554 nodes
  android_ui.py -s emulator-5554 shot out.png
"""
import argparse
import os
import re
import subprocess
import sys
import time

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
PKG = "com.digitalcircuitstudios.templeosapp"
ACT = PKG + "/io.github.templeosmobile.android.MainActivity"


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *args, check=True, capture=True, timeout=120):
        r = subprocess.run([ADB, "-s", self.serial, *args], capture_output=capture, timeout=timeout)
        if check and r.returncode != 0:
            raise RuntimeError("adb %s failed: %s" % (" ".join(args), r.stderr.decode(errors="replace")))
        return r.stdout.decode(errors="replace") if capture else ""

    def shell(self, cmd, **kw):
        return self.adb("shell", cmd, **kw)

    # ------------------------------------------------------------------ app
    def install(self, apk):
        self.adb("install", "-r", apk, timeout=300)

    def launch(self, clear=False, extras=""):
        self.shell("am force-stop " + PKG)
        if clear:
            self.shell("pm clear " + PKG)
        self.shell("am start -W -n %s %s" % (ACT, extras))
        time.sleep(2)

    def foreground_package(self):
        out = self.shell("dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity'", check=False)
        m = re.search(r"u0 ([\w.]+)/", out)
        return m.group(1) if m else ""

    def rotate(self, landscape):
        """Locks the rotation. False where the shell may not (ColorOS denies WRITE_SETTINGS without its
        'Disable permission monitoring' developer option): the device keeps its own orientation."""
        try:
            self.shell("settings put system accelerometer_rotation 0")
        except RuntimeError:
            return False
        self.shell("settings put system user_rotation %d" % (1 if landscape else 0))
        time.sleep(2)
        return True

    def size(self):
        m = re.search(r"(\d+)x(\d+)", self.shell("wm size"))
        return int(m.group(1)), int(m.group(2))

    def density(self):
        m = re.search(r"(\d+)", self.shell("wm density").splitlines()[-1])
        return int(m.group(1)) / 160.0

    # ------------------------------------------------------------------ tree
    def nodes(self):
        for _ in range(3):
            out = self.shell("uiautomator dump /sdcard/templeos-ui.xml >/dev/null && cat /sdcard/templeos-ui.xml", check=False)
            if "<node" in out:
                break
            time.sleep(0.5)
        res = []
        for m in re.finditer(r"<node [^>]*>", out):
            n = m.group(0)

            def attr(k):
                a = re.search(k + r'="([^"]*)"', n)
                return a.group(1) if a else ""
            b = [int(v) for v in re.findall(r"\d+", attr("bounds"))]
            label = attr("content-desc") or attr("text")
            if label and len(b) == 4:
                res.append({"label": unescape(label), "bounds": b, "clickable": attr("clickable") == "true",
                            "selected": attr("selected") == "true"})
        return res

    def find(self, label, exact=True, timeout=6.0):
        end = time.time() + timeout
        while True:
            for n in self.nodes():
                if (n["label"] == label) if exact else (label in n["label"]):
                    return n
            if time.time() > end:
                return None
            time.sleep(0.4)

    def tap_xy(self, x, y):
        self.shell("input tap %d %d" % (x, y))

    def tap(self, label, exact=True, timeout=6.0, settle=0.8):
        n = self.find(label, exact, timeout)
        if n is None:
            raise RuntimeError("no node %r on screen" % label)
        x0, y0, x1, y1 = n["bounds"]
        self.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        time.sleep(settle)
        return n

    def key(self, code):
        self.shell("input keyevent %s" % code)

    def shot(self, path):
        with open(path, "wb") as f:
            f.write(subprocess.run([ADB, "-s", self.serial, "exec-out", "screencap", "-p"], capture_output=True, timeout=60).stdout)

    # ------------------------------------------------------------------ logs
    def logcat_clear(self):
        self.adb("logcat", "-c", check=False)

    def logcat(self, grep="TempleOSMobile"):
        out = self.adb("logcat", "-d", "-v", "time", check=False, timeout=60)
        return [l for l in out.splitlines() if grep in l]


def unescape(s):
    import html
    return html.unescape(s)  # uiautomator escapes &, <, >, quotes and newlines (&#10;)


def parse_perf(line):
    """'TempleOSMobile perf program=x fps=30 ...' -> dict."""
    m = re.search(r"TempleOSMobile perf (.*)$", line)
    if not m:
        return None
    d = {}
    for kv in m.group(1).split():
        k, _, v = kv.partition("=")
        try:
            d[k] = float(v) if "." in v else int(v)
        except ValueError:
            d[k] = v
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", default="emulator-5554")
    ap.add_argument("cmd", choices=["nodes", "tap", "shot"])
    ap.add_argument("arg", nargs="?")
    a = ap.parse_args()
    d = Device(a.serial)
    if a.cmd == "nodes":
        for n in d.nodes():
            print(n["bounds"], repr(n["label"]))
    elif a.cmd == "tap":
        print(d.tap(a.arg))
    elif a.cmd == "shot":
        d.shot(a.arg)


if __name__ == "__main__":
    sys.exit(main())
