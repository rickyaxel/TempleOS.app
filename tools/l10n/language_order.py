#!/usr/bin/env python3
"""Language-list order on a device, and Android/iOS parity (docs/localization.md, "Language lists").

  android   Drives the app on an Android device or emulator through the accessibility tree
            (tools/performance-analysis/android_ui.py). For each locale: per-app locale (Android 13+),
            Start > Language..., the rows read top to bottom while dragging the list. Checks that
            Automatic comes first and is selected, then every manifest language exactly once. Then an
            in-app choice (Russian) re-sorts the open window and stays selected through rotation and a
            restart. Writes <out>/android.json ({"orders": {locale: [ids]}}) and screenshots.
  compare   Compares two such files (android.json and the iOS UI test's ios.json, written by
            testLanguageListOrder with TEST_RUNNER_TEMPLEOS_ORDER_OUT) locale by locale.

The order itself is defined by each platform's collator (Android ICU, Apple Foundation), so this tool
never computes an expected order; it reports where the two platforms differ.

Usage:
  language_order.py android -s emulator-5562 [--apk PATH] [--out DIR] [--locales en-US,ru-RU,...]
  language_order.py compare A.json B.json
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "performance-analysis"))
import android_ui  # noqa: E402

L10N = os.path.join(ROOT, "shared", "runtime", "l10n")
MANIFEST = json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))
LOC = {l["id"]: l for l in MANIFEST["locales"]}
ROWS = {"%s - %s" % (l["native_name"], l["english_name"]): l["id"] for l in MANIFEST["locales"]}
DEFAULT = "en-US,ru-RU,ar,ja-JP,es-ES"
OUT = os.path.join(ROOT, "docs", "localization-evidence", "language-order")


def T(loc, key):
    en = json.load(open(os.path.join(L10N, "en.json"), encoding="utf-8"))
    d = json.load(open(os.path.join(L10N, LOC[loc]["catalog"] + ".json"), encoding="utf-8"))
    return (d.get(key) or en[key]).replace("{app}", MANIFEST["app_name"])  # as L10n.tr fills it


class Run:
    def __init__(self, d, out):
        self.d, self.out, self.results = d, out, []

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        print(("PASS " if ok else "FAIL ") + name + ((": " + detail) if detail and not ok else ""))

    def shot(self, name):
        self.d.shot(os.path.join(self.out, name + ".png"))

    def open_language(self, loc):
        self.d.tap(T(loc, "topbar.menu"), timeout=15)
        label = T(loc, "menu.start.language")
        for _ in range(10):
            if self.d.find(label, timeout=1.5):
                break
            self.d.tap(T(loc, "a11y.scroll_menu_down"), timeout=2, settle=0.4)
        self.d.tap(label, settle=1.5)

    def tap_row(self, label):
        """Drags the Language window's list up until the row is on screen, then taps it."""
        self.d.key("KEYCODE_ESCAPE")
        time.sleep(0.8)
        for _ in range(30):
            nodes = [n for n in self.d.nodes() if n["clickable"]]
            hit = [n for n in nodes if n["label"] == label]
            if hit:
                b = hit[0]["bounds"]
                self.d.tap_xy((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
                time.sleep(2.5)
                return
            rows = sorted((n for n in nodes if n["label"] in ROWS), key=lambda n: n["bounds"][1])
            x = (rows[0]["bounds"][0] + rows[0]["bounds"][2]) // 2
            self.d.shell("input swipe %d %d %d %d 900" % (x, (rows[-1]["bounds"][1] + rows[-1]["bounds"][3]) // 2,
                                                         x, (rows[0]["bounds"][1] + rows[0]["bounds"][3]) // 2))
            time.sleep(0.8)
        raise RuntimeError("row %r not found" % label)

    def read(self, loc):
        """(ids top to bottom with "" for Automatic, selected id): drags the list up until no new rows."""
        auto = T(loc, "settings.language.automatic")
        self.d.key("KEYCODE_ESCAPE")  # clears the filter and returns to the top of the list
        time.sleep(0.8)
        out, selected = [], None
        for _ in range(40):
            rows = sorted((n for n in self.d.nodes() if n["clickable"] and (n["label"] in ROWS or n["label"] == auto)),
                          key=lambda n: n["bounds"][1])
            for n in rows:
                if n["selected"]:
                    selected = "" if n["label"] == auto else ROWS[n["label"]]
            ids = ["" if n["label"] == auto else ROWS[n["label"]] for n in rows]
            k = 0
            while k < len(ids) and ids[k] in out:
                k += 1
            if k == len(ids):
                break
            out += ids[k:]
            if len(rows) < 3:
                break
            x = (rows[0]["bounds"][0] + rows[0]["bounds"][2]) // 2
            y0 = (rows[-1]["bounds"][1] + rows[-1]["bounds"][3]) // 2
            y1 = (rows[0]["bounds"][1] + rows[0]["bounds"][3]) // 2
            self.d.shell("input swipe %d %d %d %d 900" % (x, y0, x, y1))
            time.sleep(0.8)
        return out, selected


def android(a):
    os.makedirs(a.out, exist_ok=True)
    d = android_ui.Device(a.serial)
    if a.apk:
        d.install(a.apk)
    sdk = int(d.shell("getprop ro.build.version.sdk").strip())
    if sdk < 33:
        sys.exit("needs per-app locales (Android 13+)")
    r = Run(d, a.out)
    d.rotate(False)
    orders = {}
    for loc in a.locales.split(","):
        d.shell("cmd locale set-app-locales %s --locales %s" % (android_ui.PKG, loc), check=False)
        d.launch(clear=True)
        time.sleep(2)
        d.shell("cmd locale set-app-locales %s --locales %s" % (android_ui.PKG, loc), check=False)  # pm clear resets it
        time.sleep(2)
        r.open_language(loc)
        r.shot("android-" + loc)
        order, selected = r.read(loc)
        langs = order[1:]
        r.check("%s: Automatic first and selected" % loc, order[:1] == [""] and selected == "", "%r %r" % (order[:1], selected))
        r.check("%s: every language once" % loc, len(langs) == len(LOC) and set(langs) == set(LOC), "%d rows" % len(langs))
        orders[loc] = langs
    if "en-US" in orders and "ru-RU" in orders:
        # in-app choice while the window is open
        d.shell("cmd locale set-app-locales %s --locales en-US" % android_ui.PKG, check=False)
        d.launch(clear=True)
        time.sleep(2)
        d.shell("cmd locale set-app-locales %s --locales en-US" % android_ui.PKG, check=False)
        time.sleep(2)
        r.open_language("en-US")
        # scrolled to and tapped like a user (typing a filter with `input text` raises the device keyboard)
        r.tap_row("Русский - Russian")
        r.shot("android-inapp-ru-tapped")
        order, selected = r.read("ru-RU")
        r.check("in-app Russian: same order as a Russian device", order[1:] == orders["ru-RU"])
        r.check("in-app Russian: Russian selected", selected == "ru-RU", repr(selected))
        r.check("Russian order differs from English", orders["ru-RU"] != orders["en-US"])
        r.shot("android-inapp-ru")
        if d.rotate(True):
            order, selected = r.read("ru-RU")
            r.check("landscape: same order and selection", order[1:] == orders["ru-RU"] and selected == "ru-RU", repr(selected))
            r.shot("android-inapp-ru-landscape")
            d.rotate(False)
        d.launch()  # restart, keeping the session
        time.sleep(2)
        if not d.find("Русский - Russian", timeout=3):
            r.open_language("ru-RU")
        order, selected = r.read("ru-RU")
        r.check("restart: same order and selection", order[1:] == orders["ru-RU"] and selected == "ru-RU", repr(selected))
        d.shell("cmd locale set-app-locales %s --locales en-US" % android_ui.PKG, check=False)
    model = d.shell("getprop ro.product.model").strip()
    rel = d.shell("getprop ro.build.version.release").strip()
    json.dump({"platform": "android", "device": "%s (Android %s)" % (model, rel), "orders": orders,
               "results": [{"check": n, "pass": ok, "detail": det} for n, ok, det in r.results]},
              open(os.path.join(a.out, "android.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
    fails = [x for x in r.results if not x[1]]
    print("%d checks, %d failed" % (len(r.results), len(fails)))
    return 1 if fails else 0


def name(i):
    return "%s - %s" % (LOC[i]["native_name"], LOC[i]["english_name"]) if i in LOC else i


def compare(a):
    x, y = (json.load(open(p, encoding="utf-8")) for p in (a.a, a.b))
    same = True
    for loc in sorted(set(x["orders"]) | set(y["orders"])):
        p, q = x["orders"].get(loc), y["orders"].get(loc)
        if p is None or q is None:
            print("%s: only in %s" % (loc, x["platform"] if q is None else y["platform"]))
            same = False
        elif p == q:
            print("%s: identical (%d languages)" % (loc, len(p)))
        else:
            same = False
            diff = [k for k in range(min(len(p), len(q))) if p[k] != q[k]]
            print("%s: %d positions differ" % (loc, len(diff)))
            for k in diff[:12]:
                print("   %2d  %-12s %-40s | %-12s %s" % (k, x["platform"], name(p[k]), y["platform"], name(q[k])))
    return 0 if same else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("android")
    p.add_argument("-s", "--serial", required=True)
    p.add_argument("--apk")
    p.add_argument("--out", default=OUT)
    p.add_argument("--locales", default=DEFAULT)
    c = sub.add_parser("compare")
    c.add_argument("a")
    c.add_argument("b")
    a = ap.parse_args()
    return android(a) if a.cmd == "android" else compare(a)


if __name__ == "__main__":
    sys.exit(main())
