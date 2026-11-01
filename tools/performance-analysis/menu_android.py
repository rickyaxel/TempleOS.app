#!/usr/bin/env python3
"""Menu-layer run on an Android device or emulator (docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md).

Portrait and landscape: the start menu, the Games submenu (scrolled), a game opened from it, its window
menu, and a tap outside that must close the menu without ending the game. Sizes are measured in dp from
the accessibility nodes (the rects a tap hits); screenshots are saved. Works on the build before the
responsive menus too (taps go through labels, not coordinates), so it measures before and after alike.

  menu_android.py -s emulator-5554 --out docs/ui-normalization/evidence/menu-sizing/android-after
"""
import argparse
import json
import os
import sys
import time

from android_ui import Device


def dp(n, density):
    b = n["bounds"]
    return [round((b[2] - b[0]) / density, 1), round((b[3] - b[1]) / density, 1)]


def run(d, out, label):
    os.makedirs(out, exist_ok=True)
    density = d.density()
    report = {"device": d.serial, "label": label, "density": density, "views": []}
    d.launch(clear=True)
    for orient in ("portrait", "landscape"):
        d.rotate(orient == "landscape")
        time.sleep(1.5)
        d.tap("MENU")
        nodes = d.nodes()
        rows = [n for n in nodes if n["label"] in ("Terminal", "Files", "About & Credits")]
        chip = next((n for n in d.nodes() if n["label"] == "TempleOS"), None)
        report["views"].append({"orientation": orient, "view": "start-menu", "rows": {n["label"]: dp(n, density) for n in rows},
                                "title": dp(chip, density) if chip else None})
        d.shot(os.path.join(out, "%s-start-menu.png" % orient))
        d.tap("Games...")
        d.shot(os.path.join(out, "%s-games.png" % orient))
        for _ in range(12):
            if d.find("Zing", timeout=0.3):
                break
            if not d.find("Scroll menu down", timeout=0.3):
                break
            d.tap("Scroll menu down", settle=0.4)
        d.shot(os.path.join(out, "%s-games-scrolled.png" % orient))
        zing = d.find("Zing", timeout=1)
        report["views"].append({"orientation": orient, "view": "games", "zingRow": dp(zing, density) if zing else None})
        d.tap("Zing", timeout=3)
        time.sleep(7)
        wm = d.find("Window menu: Zing", exact=False, timeout=5)
        ok_menu = ok_after = False
        if wm:
            report["views"].append({"orientation": orient, "view": "window-menu-button", "size": dp(wm, density)})
            d.tap(wm["label"])
            ok_menu = d.find("Pause", timeout=3) is not None
            d.shot(os.path.join(out, "%s-window-menu.png" % orient))
            w, h = d.size()
            if orient == "landscape":
                w, h = max(w, h), min(w, h)
            d.tap_xy(int(w * 0.98), int(h * 0.97))
            time.sleep(1)
            ok_after = d.find("Pause", timeout=0.5) is None and d.find("Program ended. Restart from the menu.", timeout=0.5) is None \
                and d.find("Program picture: Zing", timeout=2) is not None
        report["views"].append({"orientation": orient, "view": "dismiss", "windowMenuOpened": ok_menu, "dismissedAndStillRunning": ok_after})
        close = d.find("Close Zing", timeout=2)
        if close:
            d.tap(close["label"])
        time.sleep(1)
    d.rotate(False)
    with open(os.path.join(out, "menu-android.json"), "w") as f:
        json.dump(report, f, indent=1)
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", default="emulator-5554")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    print(json.dumps(run(Device(a.serial), a.out, a.label), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
