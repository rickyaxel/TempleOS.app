#!/usr/bin/env python3
"""Prints {locale: {key: text}} for a device run of an iOS UI test that needs localized labels (the test runner on a
phone cannot read the host's shared/runtime/l10n): pass it as TEST_RUNNER_TEMPLEOS_UI_STRINGS. English stands in
for a key a catalog lacks, as in the app.

    TEST_RUNNER_TEMPLEOS_UI_STRINGS="$(tools/ui-audit/ui_strings.py)" xcodebuild ... testTypographyMatrix

Development tool only.
"""
import json
import os
import sys

L10N = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "shared", "runtime", "l10n")
DEFAULT = "en-US,de-DE,es-ES,pl-PL,vi,ru-RU,el-GR,zh-CN,ja-JP,ko-KR,ar,he-IL,fa-IR,hi-IN,bn-BD,ta-IN,th,km-KH,my-MM,am,ka-GE"
# every key the UI tests read through ui() on a physical device (testAppNameInAbout,
# testModeratedDocumentsShowRedactionMarkers, the language/keyboard matrices): a missing key crashes the runner
KEYS = [
    "a11y.window_menu",
    "about.additions.modern",
    "about.additions.title",
    "about.credits.native",
    "about.intro.creator",
    "char.asterisk",
    "char.semicolon",
    "doc.notice.adapted.title",
    "doc.notice.original.title",
    "god.button.ten_words",
    "god.intro.entropy",
    "god.menu.instructions",
    "key.enter",
    "key.escape",
    "key.shift",
    "menu.start.about",
    "menu.start.documentation",
    "menu.start.god_words",
    "menu.start.language",
    "menu.start.settings",
    "menu.start.terminal",
    "settings.language.automatic",
    "topbar.menu",
]


def main():
    locales = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT).split(",")
    manifest = json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))
    cat = {l["id"]: l["catalog"] for l in manifest["locales"]}
    en = json.load(open(os.path.join(L10N, "en.json"), encoding="utf-8"))
    out = {}
    for loc in locales:
        d = json.load(open(os.path.join(L10N, cat[loc] + ".json"), encoding="utf-8"))
        out[loc] = {k: (d.get(k) or en[k]).replace("{app}", manifest["app_name"]) for k in KEYS}  # as L10n.tr fills it
    print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
