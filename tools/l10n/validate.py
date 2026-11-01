#!/usr/bin/env python3
"""Validates the TempleOS Mobile UI localization (docs/localization.md).

Checks:
  manifest   89 canonical locales, unique ids/aliases, 73 catalogs, en-US default, each catalog file exists,
             both names present and every language-list row ("native - English") distinct,
             app_name set (the apps' name, README "Names")
  name       the apps' name is written {app} in every catalog (filled in at run time, never
             translated); the old name "TempleOS Mobile" and the literal name appear nowhere
  keys       every key used by the Kotlin and Swift UI code exists in en.json; no unused English keys
  catalogs   every catalog has exactly the English keys, valid JSON/UTF-8, no empty values,
             identical {placeholders} and line breaks, no web domain the English value lacks
  review     values identical to English (reported, allowed for names, codes and short labels)

Usage: validate.py [--report docs/localization-coverage.md] [catalog ...]
Exit status 1 on any error.
"""
import json, os, re, sys, unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
L10N = os.path.join(ROOT, 'shared/runtime/l10n')
CODE = [os.path.join(ROOT, 'temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/ui'),
        os.path.join(ROOT, 'temple_os_swift/TempleCore/Sources/TempleCore/UI'),
        os.path.join(ROOT, 'temple_os_kotlin/app/src/main/kotlin'),
        os.path.join(ROOT, 'temple_os_swift/App/TempleOSMobile')]
# keys built at run time from data (colors, symbol names, catalog ids, filesystem errors, ...)
DYNAMIC = ('color.', 'engine.reason.', 'char.', 'files.button.', 'files.a11y.', 'catalog.', 'fs.error.', 'editor.a11y.position', 'doc.notice.')
PLACEHOLDER = re.compile(r'\{[a-z_]+\}')
# a translation may not bring in a web domain (another product's branding) that English lacks
DOMAIN = re.compile(r'\b[a-z0-9-]+\.(?:com|org|net|io|edu|education|app|dev)\b', re.I)
# the apps' name is {app}; neither the retired name nor the literal name may be written into a catalog
OLD_NAME = re.compile(r'TempleOS[ -]?Mobile|templeos\.app', re.I)

errors, warnings = [], []


def load(path):
    with open(path, 'rb') as source:
        raw = source.read()
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError as e:
        errors.append(f'{os.path.basename(path)}: not UTF-8 ({e})'); return None
    if text.startswith('﻿'):
        errors.append(f'{os.path.basename(path)}: has a BOM')
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result: errors.append(f'{os.path.basename(path)}: duplicate identifier {key}')
            result[key] = value
        return result
    try:
        value = json.loads(text, object_pairs_hook=unique_object)
        if not isinstance(value, dict):
            errors.append(f'{os.path.basename(path)}: expected a JSON object'); return None
        return value
    except (json.JSONDecodeError, ValueError) as e:
        errors.append(f'{os.path.basename(path)}: invalid JSON ({e})'); return None


def strings(d):
    return {k: v for k, v in d.items() if not k.startswith('$')}


def check_manifest():
    m = load(os.path.join(L10N, 'locales.json'))
    locs = m['locales']
    ids = [l['id'] for l in locs]
    if len(ids) != 89: errors.append(f'manifest: {len(ids)} locales, expected 89')
    if len({i.lower() for i in ids}) != len(ids): errors.append('manifest: duplicate locale ids')
    if m['default_locale'] != 'en-US' or 'en-US' not in ids: errors.append('manifest: en-US must be the default')
    seen = {}
    for l in locs:
        if not re.fullmatch(m['input_tag'], l['id'].lower()):
            errors.append(f"manifest: invalid locale identifier {l['id']}")
        if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*', l['catalog']):
            errors.append(f"manifest: invalid catalog identifier {l['catalog']}")
        if l.get('parent') is not None and l['parent'] not in ids:
            errors.append(f"manifest: {l['id']} has unknown parent {l['parent']}")
        for a in l['aliases']:
            if not re.fullmatch(m['input_tag'], a.lower()): errors.append(f'manifest: invalid alias {a}')
            if a.lower() in seen or a.lower() in {i.lower() for i in ids}:
                errors.append(f'manifest: alias {a} duplicated')
            seen[a.lower()] = l['id']
        if l['direction'] not in ('ltr', 'rtl'): errors.append(f"manifest: {l['id']} direction")
        for k in ('native_name', 'english_name'):
            if not str(l.get(k) or '').strip(): errors.append(f"manifest: {l['id']} has no {k}")
    # language lists show "native - English" and are ordered by it (LanguageList): two variants must not read alike
    rows = {}
    for l in locs:
        row = unicodedata.normalize('NFC', f"{l.get('native_name', '')} - {l.get('english_name', '')}").casefold()
        if row in rows: errors.append(f"manifest: {l['id']} and {rows[row]} show the same language-list row")
        rows.setdefault(row, l['id'])
    if not str(m.get('app_name') or '').strip(): errors.append('manifest: app_name missing')
    cats = sorted({l['catalog'] for l in locs})
    if len(cats) != 73: errors.append(f'manifest: {len(cats)} catalogs, expected 73')
    for c in cats:
        if not os.path.exists(os.path.join(L10N, c + '.json')):
            errors.append(f'catalog file missing: {c}.json')
    files = {f[:-5] for f in os.listdir(L10N) if f.endswith('.json') and f != 'locales.json'}
    for c in sorted(files - set(cats)): errors.append(f'orphaned catalog file: {c}.json')
    parents = {l['id']: l.get('parent') for l in locs}
    for locale in ids:
        visited, parent = set(), locale
        while parent in parents:
            if parent in visited:
                errors.append(f'manifest: parent cycle at {locale}'); break
            visited.add(parent); parent = parents[parent]
    for region, candidates in m.get('countries', {}).items():
        if not re.fullmatch('[A-Z]{2}', region): errors.append(f'manifest: invalid region {region}')
        for candidate in candidates:
            if candidate not in ids: errors.append(f'manifest: {region} references unknown locale {candidate}')
    return m, cats


def check_values(catalog, values, english):
    """Validate English too; json.loads otherwise silently accepts duplicate keys."""
    for key, value in values.items():
        if not isinstance(value, str) or not value.strip():
            errors.append(f'{catalog}: empty or non-string value {key}'); continue
        if '\ufffd' in value or any(unicodedata.category(ch) in ('Cs', 'Co', 'Cn') for ch in value):
            errors.append(f'{catalog}: invalid Unicode in {key}')
        if OLD_NAME.search(value): errors.append(f'{catalog}: write the apps\' name as {{app}} in {key}')
        remainder = PLACEHOLDER.sub('', value)
        if '{' in remainder or '}' in remainder:
            errors.append(f'{catalog}: invalid placeholder syntax in {key}')
        if key not in english: continue
        if not isinstance(english[key], str): continue
        if sorted(PLACEHOLDER.findall(value)) != sorted(PLACEHOLDER.findall(english[key])):
            errors.append(f'{catalog}: placeholders differ in {key}')
        if value.count('\n') != english[key].count('\n'):
            errors.append(f'{catalog}: line breaks differ in {key}')


def used_keys():
    keys = set()
    for d in CODE:
        for dp, _, fns in os.walk(d):
            for fn in fns:
                if not fn.endswith(('.kt', '.swift')): continue
                s = open(os.path.join(dp, fn), encoding='utf-8').read()
                keys |= set(re.findall(r'\btr8?\(\s*"([a-z0-9_.]+)"', s))
                keys |= set(re.findall(r'"((?:key|char)\.[a-z_]+)"', s))
                for a, b in re.findall(r'tr8?\(\s*(?:if [^?]*?|[^?(]*\?\s*)"([a-z0-9_.]+)"\s*(?:else|:)\s*"([a-z0-9_.]+)"', s):
                    keys |= {a, b}
    return {k for k in keys if not k.endswith('.')}


def main():
    targets = [a for a in sys.argv[1:] if not a.startswith('--')]
    report = sys.argv[sys.argv.index('--report') + 1] if '--report' in sys.argv else None
    if report in targets: targets.remove(report)
    manifest, cats = check_manifest()
    en = strings(load(os.path.join(L10N, 'en.json')) or {})
    check_values('en', en, {})
    used = used_keys()
    for k in sorted(used - set(en)):
        errors.append(f'en.json: key used in code but missing: {k}')
    for k in sorted(set(en) - used):
        if not k.startswith(DYNAMIC):
            warnings.append(f'en.json: key not referenced by code: {k}')
    rows = []
    for c in (targets or cats):
        if c == 'en': continue
        path = os.path.join(L10N, c + '.json')
        if not os.path.exists(path):
            rows.append((c, 0, len(en), 0, 'missing')); continue
        d = load(path)
        if d is None: rows.append((c, 0, len(en), 0, 'invalid')); continue
        s = strings(d)
        missing = [k for k in en if k not in s]
        extra = [k for k in s if k not in en]
        same = 0
        check_values(c, s, en)
        for k in extra: errors.append(f'{c}: unexpected key {k}')
        for k in missing: errors.append(f'{c}: missing key {k}')
        for k, v in s.items():
            if k not in en: continue
            if not isinstance(v, str) or not v.strip():
                errors.append(f'{c}: empty value {k}'); continue
            if {d.lower() for d in DOMAIN.findall(v)} - {d.lower() for d in DOMAIN.findall(en[k])}:
                errors.append(f'{c}: foreign domain in {k}')
            if v == en[k]: same += 1
        review = d.get('$review', [])
        rows.append((c, len(en) - len(missing), len(en), same, f'{len(review)} flagged for review' if review else ''))
    for e in errors: print('ERROR', e)
    for w in warnings: print('warn ', w)
    done = sum(1 for r in rows if r[1] == r[2])
    print(f'{len(en)} English keys; {len(used)} referenced by code; {done}/{len(rows)} catalogs complete; '
          f'{len(errors)} errors, {len(warnings)} warnings')
    if report:
        with open(os.path.join(ROOT, report), 'w', encoding='utf-8') as f:
            f.write('# Localization coverage\n\nGenerated by `tools/l10n/validate.py --report`. '
                    '"Same as English" counts values left identical to English (names, codes, short labels).\n\n'
                    f'English keys: {len(en)}. Catalogs: {len(rows) + 1} (including English). Errors: {len(errors)}.\n\n'
                    '| Catalog | Keys | Same as English | Notes |\n|---|---|---|---|\n')
            for c, n, total, same, note in rows:
                f.write(f'| `{c}` | {n}/{total} | {same} | {note} |\n')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
