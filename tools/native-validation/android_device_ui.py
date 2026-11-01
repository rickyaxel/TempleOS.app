#!/usr/bin/env python3
"""App-level native checks on an Android device, through the accessibility tree (android_ui.Device).

Drives the side-by-side bench package (com.digitalcircuitstudios.templeosapp.bench) in its normal mode, so the user's own app
and data are never touched: cold and warm launch times (am start -W), X-Caliber, Talons and Cartesian from the
menus with the native engine, the TempleOS touch keys, background/foreground, Back, closing windows. Every perf
line the app logs names its engine; all must say engine=native.

    tools/native-validation/android_device_ui.py SERIAL OUTDIR
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "performance-analysis"))
import android_ui  # noqa: E402

PKG = "com.digitalcircuitstudios.templeosapp.bench"
android_ui.PKG = PKG
android_ui.ACT = PKG + "/io.github.templeosmobile.android.MainActivity"


def main():
    serial, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    d = android_ui.Device(serial)
    report = {"steps": []}

    def step(name, **kw):
        report["steps"].append({"step": name, **kw})
        print(name, json.dumps(kw)[:300])

    d.shell("input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard", check=False)

    # launch times: cold (process stopped) and warm (activity in the background)
    cold, warm = [], []
    for _ in range(7):
        d.shell("am force-stop " + PKG)
        time.sleep(1)
        o = d.shell("am start -W -n %s --ez nosession true" % android_ui.ACT)
        m = re.search(r"TotalTime: (\d+)", o)
        if m:
            cold.append(int(m.group(1)))
        time.sleep(2)
    for _ in range(7):
        d.key("KEYCODE_HOME")
        time.sleep(1.5)
        o = d.shell("am start -W -n %s" % android_ui.ACT)
        m = re.search(r"TotalTime: (\d+)", o)
        if m:
            warm.append(int(m.group(1)))
        time.sleep(1.5)
    step("launch", cold_ms=cold, warm_ms=warm)

    d.shell("am force-stop " + PKG)
    d.logcat_clear()
    d.shell("am start -W -n %s --ez nosession true --ez perflog true --es engine native" % android_ui.ACT)
    time.sleep(3)
    d.shot(os.path.join(out, "00-desktop.png"))

    def open_program(menu, label, title):
        d.tap("MENU")
        d.tap(menu)
        for _ in range(12):
            if d.find(label, timeout=1.0):
                break
            d.tap("Scroll menu down", timeout=2.0)
        d.tap(label)
        time.sleep(4)
        for _ in range(3):  # a program's own popup (X-Caliber's first-run message)
            if d.find("OKAY", timeout=1.0):
                d.tap("OKAY")
        return title

    def perf(seconds, keys=()):
        t0 = time.time()
        i = 0
        while time.time() - t0 < seconds:
            if keys:
                n = d.find(keys[i % len(keys)], timeout=0.5)
                if n:
                    x0, y0, x1, y1 = n["bounds"]
                    d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
                i += 1
            time.sleep(0.5)
        lines = [l for l in d.logcat("TempleOSMobile perf")]
        d.logcat_clear()
        return lines

    def close(title):
        n = None
        for node in d.nodes():
            if node["label"].startswith("Close " + title):
                n = node
                break
        if n:
            x0, y0, x1, y1 = n["bounds"]
            d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
            time.sleep(2)
        return n is not None and not any(node["label"].startswith("Close " + title) for node in d.nodes())

    for menu, label, title, secs, keys in [("Games...", "X-Caliber", "X-Caliber", 20, ("Space", "Left arrow", "Up arrow")),
                                            ("Games...", "Talons (partial)", "Talons", 40, ("Up arrow",)),
                                            ("Demos...", "Cartesian", "Cartesian", 0, ())]:
        open_program(menu, label, title)
        if title == "Cartesian":
            d.shell("input text '2*x'")
            d.key("KEYCODE_ENTER")
            time.sleep(6)
            d.shot(os.path.join(out, "cartesian-2x.png"))
            d.key("KEYCODE_SPACE")
            time.sleep(1)
            d.shell("input text 'Sin(x/20)*100'")
            d.key("KEYCODE_ENTER")
            time.sleep(6)
            d.shot(os.path.join(out, "cartesian-sin.png"))
            lines = perf(3)
        else:
            lines = perf(secs / 2, keys)
            d.shot(os.path.join(out, "%s-running.png" % title))
            # background and foreground
            d.key("KEYCODE_HOME")
            time.sleep(4)
            d.shell("am start -n %s" % android_ui.ACT)
            time.sleep(3)
            lines += perf(secs / 2, keys)
            d.shot(os.path.join(out, "%s-after-foreground.png" % title))
        engines = sorted({m.group(1) for l in lines for m in [re.search(r"engine=(\w+)", l)] if m})
        fps = [int(m.group(1)) for l in lines for m in [re.search(r" fps=(\d+)", l)] if m]
        step(title, perf_lines=len(lines), engines=engines, fps=fps, sample=lines[-1][-200:] if lines else "")
        closed = close(title)
        step(title + " closed", ok=closed)

    # Back with no window open: the app goes to the background, not away
    d.key("KEYCODE_BACK")
    time.sleep(2)
    step("back", foreground=d.foreground_package())
    d.shell("am start -n %s" % android_ui.ACT)
    time.sleep(2)
    step("resume after back", foreground=d.foreground_package())
    d.shot(os.path.join(out, "99-end.png"))
    ok = all(s.get("engines") in (None, ["native"]) and s.get("ok", True) for s in report["steps"])
    ok = ok and len(cold) == 7 and len(warm) == 7
    ok = ok and report["steps"][-2]["foreground"] != PKG
    ok = ok and report["steps"][-1]["foreground"] == PKG
    report["passed"] = ok
    json.dump(report, open(os.path.join(out, "android-ui.json"), "w"), indent=1)
    print("UI checks passed:", ok)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
