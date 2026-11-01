#!/usr/bin/env python3
"""Finds user-visible English text that bypasses the catalogs (docs/localization.md).

Scans the shared UI code (Kotlin core/ui, Swift TempleCore/UI) for string literals with
letters passed straight to the calls that put text on screen or in a screen reader:
uiText, text (window/console text), MenuItem, templeButton, a11yButton, a11yText, toast,
Dialog titles and messages. Literals that are TempleOS content or technical tokens (paths, file
names, HolyC, single symbols, key caps) are allowed by ALLOW; anything else is reported.

Exit status 1 when something is reported.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIRS = ['temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/ui',
        'temple_os_swift/TempleCore/Sources/TempleCore/UI']
CALLS = r'(?:uiText|\.text|MenuItem|templeButton|a11yButton|a11yText|toast|Dialog\.\w+|showToast|label\s*=|title\s*=)'
CALL = re.compile(CALLS + r'\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)')
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
ALLOW = [
    re.compile(r'^[^A-Za-z]*$'),                       # numbers, symbols, box drawing
    re.compile(r'^[A-Z]:/'),                            # TempleOS paths
    re.compile(r'\.(HC|DD|TXT|GR|HH|BIN)\b', re.I),     # file names
    re.compile(r'^\$|\$\{|\\\('),                       # pure interpolation
    # CP437 names the original character set; insertion guidance is localized separately.
    re.compile(r'^(TempleOS|HolyC|DolDoc|CP437|FPS|OK|x|X|DIR\+?|KiB|MiB|v\d.*)$'),
    re.compile(r'^(ESC|TAB|CTRL|ALT|SYS|HIDE|SHIFT|BKSP|SYM|FN|SPACE|ENTER|DEL|INS|HOME|END|PGUP|PGDN|F\d+|ABC|123)$'),  # TempleOS key caps
    re.compile(r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),    # catalog keys (tr("..."))
    re.compile(r'^[a-z]+$'),                            # app kinds, ids
    re.compile(r'^(\\u[0-9A-Fa-f]{4}|\\u\{[0-9A-Fa-f]+\})+$'),  # TempleOS font glyphs by code
    re.compile(r'^%\d*l?d FPS$'),                        # frame counter, as TempleOS shows it
]
# file:line suppressions with a reason: "# l10n-ok: <reason>" (Kotlin/Swift: // l10n-ok)
SUPPRESS = re.compile(r'//\s*l10n-ok')


def main():
    found = []
    for d in DIRS:
        for dp, _, fns in os.walk(os.path.join(ROOT, d)):
            for fn in sorted(fns):
                if not fn.endswith(('.kt', '.swift')) or fn.startswith(('L10n', 'Json')):
                    continue
                path = os.path.join(dp, fn)
                for no, line in enumerate(open(path, encoding='utf-8'), 1):
                    if SUPPRESS.search(line) or line.lstrip().startswith(('//', '*', '/*')):
                        continue
                    for m in CALL.finditer(line):
                        args = m.group(1)
                        # literals inside tr(...) are keys; drop them
                        args = re.sub(r'\btr8?\(\s*"[^"]*"', 'tr(', args)
                        for lit in LIT.findall(args):
                            if not re.search(r'[A-Za-z]{2}', lit) or any(a.search(lit) for a in ALLOW):
                                continue
                            found.append(f'{os.path.relpath(path, ROOT)}:{no}: "{lit}"')
    for f in found:
        print(f)
    print(f'{len(found)} hard-coded UI string(s)')
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
