#!/usr/bin/env python3
"""Finds user-visible English text that bypasses the catalogs (docs/localization.md).

Scans the shared UI code (Kotlin core/ui, Swift TempleCore/UI) and the platform layers for string
literals with letters passed straight to the calls that put text on screen or in a screen reader:
uiText, text (window/console text), MenuItem, templeButton, a11yButton, a11yText, toast, Dialog
titles and messages, and the game controls' Btn. Literals that are TempleOS content or technical
tokens (paths, file names, HolyC, single symbols, key caps) are allowed by ALLOW; anything else is
reported.

Two more leaks it reports:
  - a platform accessibility label or description assigned a literal (VoiceOver, TalkBack);
  - an FsError created without a catalog key in kernel or UI code: FsError.localized() then shows
    its English message.
REVIEWED lists the reviewed exceptions, each with its reason.

Exit status 1 when something is reported.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIRS = ['temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/ui',
        'temple_os_swift/TempleCore/Sources/TempleCore/UI']
PLATFORM_DIRS = ['temple_os_kotlin/app/src/main/kotlin/io/github/templeosmobile/android',
                 'temple_os_swift/App/TempleOSMobile']
KERNEL_DIRS = ['temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/kernel',
               'temple_os_swift/TempleCore/Sources/TempleCore/Kernel']
CALLS = r'(?:uiText|\.text|MenuItem|templeButton|a11yButton|a11yText|toast|Dialog\.\w+|showToast|label\s*=|title\s*=|\bBtn)'
CALL = re.compile(CALLS + r'\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)')
# accessibilityLabel = "...", contentDescription = "..." (platform screen-reader text)
A11Y_ASSIGN = re.compile(r'\b(?:accessibilityLabel|accessibilityHint|accessibilityValue|contentDescription|tooltipText)\s*=\s*("(?:[^"\\]|\\.)*")')
FS_ERROR = re.compile(r'\bFsError\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
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
# Reviewed exceptions: (file name, literal or message prefix, reason).
REVIEWED = [
    ('TempleView.swift', 'TempleOS desktop',
     'label of the container view (isAccessibilityElement = false): VoiceOver reads its child elements, not this'),
    ('AccessibilityAdapter.kt', 'TempleOS input;',
     'debug and benchmark builds only (BuildConfig.DEBUG || BENCH): input diagnostics read by test tools'),
    ('GRImage.kt', '', 'picture decoder detail, shown inside the localized frame paint.invalid_picture'),
    ('GRImage.swift', '', 'picture decoder detail, shown inside the localized frame paint.invalid_picture'),
    ('DocumentRuntime.kt', 'Program document is still running',
     'guard: the UI offers Save as only once DocumentRuntime.canExport() is true'),
    ('DocumentRuntime.swift', 'Program document is still running',
     'guard: the UI offers Save as only once DocumentRuntime.canExport() is true'),
    ('DocumentRuntime.kt', 'No file system',
     'kernels without a file system (benchmarks, tests); the app\'s UiKernelEnv always has one'),
]
# file:line suppressions with a reason: "# l10n-ok: <reason>" (Kotlin/Swift: // l10n-ok)
SUPPRESS = re.compile(r'//\s*l10n-ok')


def reviewed(fn, text):
    return any(fn == f and text.startswith(prefix) for f, prefix, _ in REVIEWED)


def depth(line):
    """Open minus closed parentheses outside string literals."""
    code = LIT.sub('""', line)
    return code.count('(') - code.count(')')


def sources(dirs):
    """Source lines; a line that leaves a call open is joined with the next ones (up to 3)."""
    for d in dirs:
        for dp, _, fns in os.walk(os.path.join(ROOT, d)):
            for fn in sorted(fns):
                if not fn.endswith(('.kt', '.swift')):
                    continue
                path = os.path.join(dp, fn)
                lines = open(path, encoding='utf-8').read().split('\n')
                for i, line in enumerate(lines):
                    if SUPPRESS.search(line) or line.lstrip().startswith(('//', '*', '/*')):
                        continue
                    j = i
                    while depth(line) > 0 and j < i + 3 and j + 1 < len(lines):
                        j += 1; line += ' ' + lines[j].strip()
                    yield fn, f'{os.path.relpath(path, ROOT)}:{i + 1}', line


def main():
    found = []
    for fn, where, line in sources(DIRS + PLATFORM_DIRS):
        if fn.startswith(('L10n', 'Json')) or fn.startswith(('BenchMode', 'NativeKeyboardDiagnostics', 'ImeDiagnostics')):
            continue
        for m in CALL.finditer(line):
            args = m.group(1)
            # literals inside tr(...) are keys; drop them
            args = re.sub(r'\btr8?\(\s*"[^"]*"', 'tr(', args)
            for lit in LIT.findall(args):
                if not re.search(r'[A-Za-z]{2}', lit) or any(a.search(lit) for a in ALLOW):
                    continue
                found.append(f'{where}: "{lit}"')
        for m in A11Y_ASSIGN.finditer(line):
            lit = m.group(1)[1:-1]
            if re.search(r'[A-Za-z]{2}', lit) and not reviewed(fn, lit):
                found.append(f'{where}: "{lit}" (screen-reader text)')
    for fn, where, line in sources(DIRS + KERNEL_DIRS):
        for m in FS_ERROR.finditer(line):
            if not reviewed(fn, m.group(1)):
                found.append(f'{where}: FsError("{m.group(1)}") has no catalog key')
    for f in found:
        print(f)
    print(f'{len(found)} hard-coded UI string(s)')
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
