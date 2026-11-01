#!/usr/bin/env python3
"""Build the read-only bundled C:/ drive for both apps.

Development-only, reproducible. Copies files from the byte-exact TempleOS V5.03
extraction (tools/asset-extraction/extract_templeos_iso.py) plus TempleOS
Mobile's own example programs (shared/home-src) into shared/bundled-fs/, and
writes shared/bundled-fs.index (one line per entry: D|F <TAB> path <TAB> size
<TAB> sha256 <TAB> origin <TAB> mtime) which the virtual filesystem uses for listings.
mtime is the RedSea date from the ISO as wall-clock milliseconds (the local time
Terry's machine recorded, not converted to UTC), or 0 when unknown.

Usage: build_bundled_fs.py <templeos-iso dir> <shared dir>
"""
import hashlib, json, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import moderation  # noqa: E402

EXCLUDE_PREFIXES = [
    'Adam/AutoComplete/',      # 26 MB word-completion dictionary for the desktop editor
    '0000Boot/',               # x86 boot image
    'Downloads/Linux/',        # host-side Linux helper tools
]
EXCLUDE_SUFFIXES = ['.BIN', '.BIN.C', '.MAP', '.ISO', '.ISO.C']
EXCLUDE_FILES = {
    'MANIFEST.json',
    # Doc/Credits.DD: "taken from OrientDisplay ... without permission" -
    # not public domain, and not needed (the system font is Kernel/FontStd.HC).
    'Kernel/FontCyrillic.HC',
    # A 2017 templeos.org web-server log with ~213 visitor IP addresses
    # (personal data; not known to be scrambled). Only used by WebLogDemo,
    # which is not in the program catalog.
    'Demo/WebLogDemo/access_170622.log',
}

# Files inside the TempleOS distribution that Terry A. Davis did not write
# (see Doc/Credits.DD); recorded with their real origin.
ORIGIN_OVERRIDES = {
    'Misc/Bible.TXT': 'Project Gutenberg Etext #10, King James Bible (public-domain text; '
                      'Gutenberg header retained), as distributed with TempleOS V5.03',
    'Kernel/FontStd.HC': 'TempleOS V5.03; font data from FreeDOS (public domain per Doc/Credits.DD)',
    # "I included PCIDevice Lst File" (Doc/Credits.DD): the vendor/device list from pcidatabase.com
    'Misc/PCIDevices.DD': 'PCI vendor and device list from pcidatabase.com (Doc/Credits.DD), as distributed with TempleOS V5.03',
}

# Content moderation (moderation.py, moderation.json; docs/content-moderation/CONTENT_MODERATION.md):
# offensive words, slurs and remarks about groups of people in original files are censored or
# redacted with visible markers, in the text part only (embedded sprites after the NUL are
# untouched). The originals stay in the ISO extraction; only the moderated copies are bundled,
# and the index records them as "modified".
MODERATED_ORIGIN_SUFFIX = '; modified: offensive content censored or redacted by TempleOS.app'


def censor(rel, data):
    return moderation.moderate(rel, data)


def year_start_date(year):
    # Kernel/KDate.HC YearStartDate: day since AD 0 of January 1st
    y1 = year - 1
    return year * 365 + y1 // 4 - y1 // 100 + y1 // 400 - y1 // 4000


def cdate_to_ms(cdt):
    # CDate: day since AD 0 in the high 32 bits, fraction of the day * 2^32 in the low 32
    if not cdt:
        return 0
    day, frac = cdt >> 32, cdt & 0xFFFFFFFF
    return (day - year_start_date(1970)) * 86400000 + frac * 86400000 // (1 << 32)


def wanted(rel):
    if any(part.startswith('.') for part in rel.split('/')):
        return False  # host metadata such as .DS_Store
    if rel in EXCLUDE_FILES:
        return False
    if any(rel.startswith(p) for p in EXCLUDE_PREFIXES):
        return False
    if any(rel.upper().endswith(s) for s in EXCLUDE_SUFFIXES):
        return False
    return True


def main(iso, shared):
    out = os.path.join(shared, 'bundled-fs')
    if os.path.exists(out):
        shutil.rmtree(out)
    entries = []
    dates = {}
    mf = os.path.join(iso, 'MANIFEST.json')
    if os.path.exists(mf):
        m = json.load(open(mf))
        for k, v in list(m.get('files', {}).items()) + list(m.get('dirs', {}).items()):
            dates[k] = cdate_to_ms(v.get('cdate', 0))
    sources = [(iso, 'TempleOS V5.03 (public domain, Terry A. Davis)'),
               (os.path.join(shared, 'home-src'), 'TempleOS Mobile')]
    for root_dir, origin in sources:
        if not os.path.isdir(root_dir):
            continue
        for dp, dn, fn in os.walk(root_dir):
            dn.sort()
            for f in sorted(fn):
                src = os.path.join(dp, f)
                rel = os.path.relpath(src, root_dir).replace(os.sep, '/')
                if not wanted(rel):
                    continue
                dst = os.path.join(out, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                data, changed = censor(rel, open(src, 'rb').read())
                open(dst, 'wb').write(data)
                o = ORIGIN_OVERRIDES.get(rel, origin) + (MODERATED_ORIGIN_SUFFIX if changed else '')
                ms = dates.get(rel, 0) if root_dir == iso else 0
                entries.append(('F', rel, len(data), hashlib.sha256(data).hexdigest(), o, ms))
    dirs = set()
    for _, rel, *_ in entries:
        parts = rel.split('/')[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add('/'.join(parts[:i]))
    lines = [f'D\t{d}\t0\t-\t-\t{dates.get(d, 0)}' for d in sorted(dirs)]
    lines += [f'F\t{rel}\t{size}\t{sha}\t{origin}\t{ms}' for _, rel, size, sha, origin, ms in sorted(entries, key=lambda e: e[1])]
    open(os.path.join(shared, 'bundled-fs.index'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    total = sum(e[2] for e in entries)
    print(f'{len(entries)} files, {len(dirs)} dirs, {total / 1024 / 1024:.1f} MiB')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
