#!/usr/bin/env python3
"""TempleOS UI policy check (docs/ui-normalization/PLATFORM_UI_ABSTRACTION.md).

All app-owned UI is drawn by the shared core in the TempleOS palette and font. This check
fails when app or core sources use a native widget or appearance API, or a raw color outside
the palette, unless the use is on the allowlist below with a reason. Native infrastructure
(views, input connections, accessibility, insets) is not a violation.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN = [
    ('temple_os_swift/App/TempleOSMobile', '.swift'),
    ('temple_os_swift/TempleCore/Sources', '.swift'),
    ('temple_os_kotlin/app/src/main', '.kt'),
    ('temple_os_kotlin/core/src/main', '.kt'),
    ('temple_os_kotlin/app/src/main/res', '.xml'),
]
RULES = [
    # iOS native widgets and presentation
    (r'\bimport SwiftUI\b|\bNavigationStack\b|\bNavigationView\b|\bTabView\b|\.sheet\(|\.alert\(|\.confirmationDialog\(', 'SwiftUI presentation'),
    (r'\bUI(Button|Label|TextField|TextView|Slider|Switch|TableView|CollectionView|NavigationController|NavigationBar|TabBar(Controller)?|AlertController|Menu|ContextMenuInteraction|ActivityIndicatorView|ProgressView|PickerView|SegmentedControl|Stepper|ToolBar|Toolbar|SearchBar)\b', 'UIKit widget'),
    (r'systemName:|UIImage\(systemName|SF Symbol', 'SF Symbols'),
    (r'UIColor\.(system|label|secondary|tint)|\.tintColor|UIColor\(red:|UIColor\(named:', 'UIKit system color'),
    # Android native widgets and presentation
    (r'android\.widget\.(Button|TextView|EditText|Toast|ProgressBar|SeekBar|Switch|ScrollView|PopupMenu|ListView|Spinner|CheckBox|RadioButton|ImageButton)\b', 'Android widget'),
    (r'\bToast\.makeText\b|\bAlertDialog\b|\bSnackbar\b|\bandroidx\.|\bcom\.google\.android\.material\b|\bandroidx\.compose\b|\bToolbar\b|\bActionBar\b', 'Android dialog/toolbar/library'),
    (r'Color\.parseColor|android\.graphics\.Color\.(rgb|argb)', 'Android raw color'),
    (r'<(Button|TextView|EditText|ProgressBar|SeekBar|Switch|Toolbar|ListView|RecyclerView)\b', 'Android XML widget'),
    # raw colors (ARGB literals) outside the palette: UI and platform code only (the
    # interpreter's bit masks such as 0xFFFFFFFF are not colors)
    (r'0xFF[0-9A-Fa-f]{6}\b', 'raw ARGB color literal'),
]
UI_ONLY = {'raw ARGB color literal'}
UI_DIRS = ('/ui/', '/UI/', 'temple_os_swift/App/', 'temple_os_kotlin/app/', 'kernel/Palette.kt', 'Kernel/Keys.swift')
# (path suffix, rule label, reason)
ALLOW = [
    ('core/kernel/Palette.kt', 'raw ARGB color literal', 'the TempleOS palette itself (tokens.json)'),
    ('TempleCore/Kernel/Keys.swift', 'raw ARGB color literal', 'the TempleOS palette itself (Palette.STD, tokens.json)'),
    ('TempleOSMobile/TempleView.swift', 'UIKit system color', 'TempleView.color: a Palette.STD entry converted to UIColor for UIKit text drawing (text runs, docs/localization.md) and for the view/window backgrounds that continue the SystemChrome gutters (docs/ui-normalization/SYSTEM_CHROME.md); never a system color'),
    ('android/AccessibilityAdapter.kt', 'Android widget', 'TalkBack role names ("android.widget.Button") for virtual nodes, not widgets'),
]

def allowed(path, label):
    return any(path.endswith(sfx) and label == lab for sfx, lab, _ in ALLOW) or any(
        sfx in path and label == lab for sfx, lab, _ in ALLOW)

violations = 0; files = 0
for rel, ext in SCAN:
    base = os.path.join(ROOT, rel)
    for dp, _, fns in os.walk(base):
        for fn in fns:
            if not fn.endswith(ext): continue
            p = os.path.join(dp, fn); files += 1
            shown = os.path.relpath(p, ROOT)
            for i, line in enumerate(open(p, encoding='utf-8', errors='replace'), 1):
                code = line.split('//')[0] if ext != '.xml' else line
                for pat, label in RULES:
                    if label in UI_ONLY and not any(d in shown for d in UI_DIRS): continue
                    if re.search(pat, code) and not allowed(shown.replace(os.sep, '/').replace('io/github/templeosmobile/', ''), label):
                        print(f'{shown}:{i}: {label}: {line.strip()[:120]}'); violations += 1
print(f'{files} files scanned, {violations} violations, {len(ALLOW)} allowlisted exceptions')
sys.exit(1 if violations else 0)
