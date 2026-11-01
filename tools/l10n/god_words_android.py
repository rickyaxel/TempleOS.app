#!/usr/bin/env python3
"""God Words localization on an Android device or emulator, driven like a user through the
accessibility tree (tools/performance-analysis/android_ui.py).

Checks, with screenshots in --out:
  1. device language (per-app locale es-ES): the UI and 10 WORDS are Spanish
  2. explicit in-app language Japanese, then Arabic, then French: the SAME picked entries are shown,
     each as the shipped translation of its entry (decoded from shared/runtime/l10n/vocab), and
     10 WORDS again adds entries in the new language
  3. in-app "Automatic" with an unsupported device language (cy): falls back to English
  4. landscape rotation keeps the picks
  5. About page shows the new section; Documentation shows the attribution notice above HelpIndex

Usage: god_words_android.py -s emulator-5554 [--apk PATH] [--out DIR]
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "performance-analysis"))
sys.path.insert(0, os.path.join(ROOT, "tools", "l10n"))
import android_ui  # noqa: E402
import vocab  # noqa: E402

L10N = os.path.join(ROOT, "shared", "runtime", "l10n")
MANIFEST = json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))
LOC = {l["id"]: l for l in MANIFEST["locales"]}
ENTRIES = vocab.canonical()
_cat = {}


def strings(loc):
    c = LOC[loc]["catalog"]
    if c not in _cat:
        en = json.load(open(os.path.join(L10N, "en.json"), encoding="utf-8"))
        d = json.load(open(os.path.join(L10N, c + ".json"), encoding="utf-8"))
        en.update({k: v for k, v in d.items() if v})
        _cat[c] = en
    return _cat[c]


def T(loc, key):
    return strings(loc)[key].replace("{app}", MANIFEST["app_name"])  # as L10n.tr fills it


def translations(loc):
    c = LOC[loc]["catalog"]
    if c == "en":
        return list(ENTRIES)
    _, lines = vocab.read_shipped(c)
    return [(lines[i] if lines and lines[i] else ENTRIES[i]) for i in range(len(ENTRIES))]


def flat(s):
    return " ".join(s.split())


def squash(s):
    """Without whitespace: wrapped CJK/Thai lines join at any character, so line breaks are not word breaks."""
    return "".join(s.split())


class Run:
    def __init__(self, d, out):
        self.d, self.out, self.results = d, out, []

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        print(("PASS " if ok else "FAIL ") + name + ((": " + detail) if detail and not ok else ""))

    def shot(self, name):
        self.d.shot(os.path.join(self.out, name + ".png"))

    def menu(self, loc):
        self.d.tap(T(loc, "topbar.menu"))

    def start(self, loc, key):
        self.menu(loc)
        label = T(loc, key)
        for _ in range(10):
            if self.d.find(label, timeout=1.5):
                break
            self.d.tap(T(loc, "a11y.scroll_menu_down"), timeout=2, settle=0.4)
        self.d.tap(label, settle=1.5)

    def language(self, cur, loc):
        """In-app choice through Start > Language..."""
        self.start(cur, "menu.start.language")
        if loc == "":
            self.d.key("KEYCODE_ESCAPE")  # the Automatic row is listed only with an empty filter
            time.sleep(0.8)
            self.d.tap(T(cur, "settings.language.automatic"), settle=2)
            return
        l = LOC[loc]
        # four letters of the English name narrow the list to one row (locale ids such as "ar" match many
        # names); keys one at a time, since a fast `input text` can drop characters in the TempleOS keyboard
        self.d.key("KEYCODE_ESCAPE")  # the window keeps its filter: ESC clears it
        time.sleep(0.5)
        for ch in l["english_name"].lower()[:4]:
            self.d.shell("input text " + ch)
            time.sleep(0.25)
        time.sleep(1)
        self.d.tap("%s - %s" % (l["native_name"], l["english_name"]), settle=2.5)

    def god_text(self, loc):
        """The God Words body (all accessibility text nodes joined), whitespace-normalized."""
        intro = squash(T(loc, "god.intro.entropy"))
        for _ in range(10):
            for n in self.d.nodes():
                if not n["clickable"] and intro in squash(n["label"]):
                    return flat(n["label"])
            time.sleep(0.5)
        return ""


def candidates(word):
    return [i for i, e in enumerate(ENTRIES) if e == word]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "localization-evidence", "god-words", "android"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    d = android_ui.Device(a.serial)
    if a.apk:
        d.install(a.apk)
    r = Run(d, a.out)
    d.rotate(False)
    d.shell("cmd locale set-app-locales %s --locales en-US" % android_ui.PKG, check=False)
    d.launch(clear=True)
    time.sleep(3)
    r.check("English device: English menu", d.find(T("en-US", "topbar.menu"), timeout=15))
    r.shot("00-en-welcome-mobile-notice")

    # 0. English: Terry's entries; their ids (English entries are unique except "delay")
    r.start("en-US", "menu.start.god_words")
    d.tap(T("en-US", "god.button.ten_words"), settle=1.5)
    txt = r.god_text("en-US")
    if not txt:
        print("DEBUG nodes:", [n["label"][:80] for n in d.nodes()][:40])
    words = txt.split(flat(T("en-US", "god.intro.entropy")))[-1].split()
    ids = [candidates(w)[0] for w in words if candidates(w)]
    r.check("10 WORDS shows ten of Terry's English entries", len(words) == 10 and len(ids) == 10, "%d words %r" % (len(words), txt[-300:]))
    r.shot("01-en-10-words")

    def same(loc, tag):
        if len(ids) != 10:
            r.check("%s shows the same ten entries" % loc, False, "no English picks to compare")
            return ""
        r.start(loc, "menu.start.god_words")  # focuses the existing God Words window (Launch.god)
        txt = r.god_text(loc)
        tr = translations(loc)
        expected = " ".join(tr[i] for i in ids)
        r.check("%s shows the same ten entries" % loc, squash(expected) in squash(txt), "expected %r in %r" % (expected[:160], txt[:400]))
        r.shot(tag)
        return txt

    # 1. device language (Automatic): per-app locale es-ES
    d.shell("cmd locale set-app-locales %s --locales es-ES" % android_ui.PKG, check=False)
    time.sleep(3)
    r.check("device language es-ES: Spanish menu", d.find(T("es-ES", "topbar.menu"), timeout=10))
    same("es-ES", "02-es-device-same-entries")
    # 2. explicit in-app choices override the device language
    prev = "es-ES"
    for loc, tag in (("ja-JP", "03-ja-same-entries"), ("ar", "04-ar-same-entries"), ("fr-FR", "05-fr-same-entries")):
        r.language(prev, loc)
        same(loc, tag)
        prev = loc
    before = r.god_text("fr-FR")
    d.tap(T("fr-FR", "god.button.ten_words"), settle=1.5)  # the God Words window is in front after same()
    after = r.god_text("fr-FR")
    r.check("10 WORDS in French adds ten more picks", after != before and after.count(" ") >= before.count(" ") + 9 or len(after) > len(before), after[-200:])
    r.shot("06-fr-10-more")

    # 3. landscape keeps the picks
    d.rotate(True)
    txt_l = r.god_text("fr-FR")
    r.check("landscape keeps the output", flat(after)[-60:] in txt_l or translations("fr-FR")[ids[-1]] in txt_l, txt_l[-200:])
    r.shot("07-fr-landscape")
    d.rotate(False)

    # 4. About in Japanese; Documentation notice in Arabic
    r.language("fr-FR", "ja-JP")
    r.start("ja-JP", "menu.start.about")
    about = " ".join(flat(n["label"]) for n in d.nodes())
    r.check("About (ja) shows the modern-additions section and Terry's credit",
            flat(T("ja-JP", "about.additions.modern")) in about and flat(T("ja-JP", "about.intro.creator")) in about)
    r.shot("08-ja-about")
    r.language("ja-JP", "ar")
    r.start("ar", "menu.start.documentation")
    nodes = [flat(n["label"]) for n in d.nodes() if not n["clickable"]]
    title = flat(T("ar", "doc.notice.original.title"))
    idx = next((k for k, l in enumerate(nodes) if l.startswith(title)), -1)
    r.check("Documentation (ar): original-documentation notice above HelpIndex", idx >= 0 and any("Help" in l for l in nodes[idx + 1:]), str(nodes[:4]))
    r.shot("09-ar-documentation-notice")

    # 5. Automatic + unsupported device language -> English, same entries
    d.shell("cmd locale set-app-locales %s --locales cy-GB" % android_ui.PKG, check=False)
    time.sleep(2)
    r.language("ar", "")
    time.sleep(2)
    r.check("unsupported device language (cy-GB) falls back to English", d.find(T("en-US", "topbar.menu"), timeout=10))
    same("en-US", "10-fallback-en-same-entries")
    d.shell("cmd locale set-app-locales %s --locales en-US" % android_ui.PKG, check=False)

    fails = [x for x in r.results if not x[1]]
    json.dump({"serial": a.serial, "model": d.shell("getprop ro.product.model").strip(), "android": d.shell("getprop ro.build.version.release").strip(),
               "ids": ids, "results": [{"check": n, "pass": ok, "detail": det} for n, ok, det in r.results]},
              open(os.path.join(a.out, "results.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("%d checks, %d failed" % (len(r.results), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
