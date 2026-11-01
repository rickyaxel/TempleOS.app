#!/usr/bin/env python3
"""Typography matrix on an Android device or emulator (docs/typography/TEMPLEOS_TYPOGRAPHY.md §6).

For one locale of each script family: the desktop, the Start menu, God Words (10 WORDS) and About, as PNGs in
--out, and typography.json with the edge steepness of the localized MENU button and three Start-menu labels (the
largest one-pixel luminance step relative to the label's contrast: text rasterized at the display's resolution
measures about 0.5-1.0, text stretched from a lower resolution about 1/stretch). The iOS counterpart is the UI test
testTypographyMatrix. Driven through the accessibility tree (tools/performance-analysis/android_ui.py).

    typography_matrix_android.py -s emulator-5554 [--apk PATH] --out DIR [--locales en-US,ja-JP,...] [--keep-data]

--keep-data (an owner's phone, Android 13+): no `pm clear`; the app's language is set per locale and given back
at the end, and the session's windows are left as they are.

Development tool only (adb, Pillow).
"""
import argparse
import json
import os
import sys
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "performance-analysis"))
import android_ui  # noqa: E402

L10N = os.path.join(ROOT, "shared", "runtime", "l10n")
LOC = {l["id"]: l for l in json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))["locales"]}
DEFAULT = "en-US,es-ES,pl-PL,vi,ru-RU,el-GR,zh-CN,ja-JP,ko-KR,ar,he-IL,fa-IR,hi-IN,bn-BD,ta-IN,th,km-KH,my-MM,am,ka-GE"


def T(loc, key):
    en = json.load(open(os.path.join(L10N, "en.json"), encoding="utf-8"))
    d = json.load(open(os.path.join(L10N, LOC[loc]["catalog"] + ".json"), encoding="utf-8"))
    return d.get(key) or en[key]


def steepness(img):
    """Edge steepness of a label region (None if it has too little contrast to measure)."""
    g = img.convert("L")
    w, h = g.size
    p = g.load()
    vals = [p[x, y] for y in range(h) for x in range(w)]
    lo, hi = min(vals), max(vals)
    if hi - lo < 40 or w < 4 or h < 4:
        return None
    d = [abs(p[x + 1, y] - p[x, y]) for y in range(h) for x in range(w - 1)]
    d += [abs(p[x, y + 1] - p[x, y]) for y in range(h - 1) for x in range(w)]
    d.sort()
    return d[int(len(d) * 0.995)] / (hi - lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk")
    ap.add_argument("--out", required=True)
    ap.add_argument("--locales", default=DEFAULT)
    ap.add_argument("--keep-data", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    d = android_ui.Device(a.serial)
    if a.apk:
        d.install(a.apk)
    d.rotate(False)
    sdk = int(d.shell("getprop ro.build.version.sdk").strip() or "0")
    if a.keep_data and sdk < 33:
        sys.exit("--keep-data needs per-app locales (Android 13+)")
    before = d.shell("cmd locale get-app-locales " + android_ui.PKG, check=False).strip() if sdk >= 33 else ""
    before = before[before.find("[") + 1:before.rfind("]")] if "[" in before else ""
    report, low = [], []
    for loc in a.locales.split(","):
        d.shell("am force-stop " + android_ui.PKG)
        if not a.keep_data:
            d.shell("pm clear " + android_ui.PKG)  # a fresh session (clearing also resets the app's locale: set it after)
        if sdk >= 33:
            d.shell("cmd locale set-app-locales %s --locales %s" % (android_ui.PKG, loc), check=False)
        else:
            # no per-app locales before Android 13: the app's own language setting (Settings g=, debug build: run-as)
            d.launch()
            time.sleep(3)
            d.shell("am force-stop " + android_ui.PKG)
            d.shell("run-as %s sed -i 's/;g=.*/;g=%s/' files/session.txt" % (android_ui.PKG, loc))
        d.launch()
        time.sleep(3)
        menu = T(loc, "topbar.menu")
        d.find(menu, timeout=15)
        base = os.path.join(a.out, "typo-%s" % loc)
        d.shot(base + "-1-desktop.png")

        def measure(label, what, shot):
            n = d.find(label, timeout=3)
            if not n:
                return
            x0, y0, x1, y1 = n["bounds"]
            v = steepness(Image.open(shot).crop((x0, y0, x1, y1)))
            report.append({"locale": loc, "what": what, "label": label, "steepness": -1 if v is None else round(v, 3)})
            if v is not None and v < 0.42:
                low.append("%s %s %r: %.2f" % (loc, what, label, v))

        measure(menu, "topbar.menu", base + "-1-desktop.png")
        d.tap(menu, settle=1.0)
        d.shot(base + "-2-start-menu.png")
        for key in ("menu.start.god_words", "menu.start.settings", "menu.start.about"):
            measure(T(loc, key), key, base + "-2-start-menu.png")
        d.tap(T(loc, "menu.start.god_words"), settle=1.5)
        try:
            d.tap(T(loc, "god.button.ten_words"), settle=1.5)
        except RuntimeError:
            pass
        d.shot(base + "-3-god-words.png")
        d.tap(menu, settle=1.0)
        d.tap(T(loc, "menu.start.about"), settle=1.5)
        d.shot(base + "-4-about.png")
        if loc in ("ja-JP", "ar") and d.rotate(True):
            d.shot(base + "-5-landscape.png")
            d.rotate(False)
        print(loc, "done", flush=True)
    if sdk >= 33:
        # back to what it was ('' = follow the system); a fresh install's matrix ends in en-US
        back = before if a.keep_data else "en-US"
        d.shell("cmd locale set-app-locales %s --locales %s" % (android_ui.PKG, back or "''"), check=False)
    json.dump(report, open(os.path.join(a.out, "typography.json"), "w"), indent=1, ensure_ascii=False)
    print("labels below 0.42:", low or "none")
    return 1 if low else 0


if __name__ == "__main__":
    sys.exit(main())
