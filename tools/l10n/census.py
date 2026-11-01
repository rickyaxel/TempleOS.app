#!/usr/bin/env python3
"""Reproducible localization census, including data-driven UI outside tr() calls.

Resource coverage measures nonempty, correctly typed registered values only. It is
not linguistic approval or evidence that every app-owned string is registered.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib

from gen_platform import ANDROID_TAG, IOS_TAG

ROOT = Path(__file__).resolve().parents[2]
L10N = ROOT / 'shared/runtime/l10n'
SCRIPTS = {
    **dict.fromkeys('be bg kk ky mk mn ru sr uk'.split(), 'Cyrillic'),
    **dict.fromkeys('ar fa ur'.split(), 'Arabic'),
    **dict.fromkeys('hi mr ne'.split(), 'Devanagari'),
    'am': 'Ethiopic', 'bn': 'Bengali', 'el': 'Greek', 'gu': 'Gujarati',
    'he': 'Hebrew', 'hy': 'Armenian', 'ja': 'Han / Hiragana / Katakana',
    'ka': 'Georgian', 'km': 'Khmer', 'kn': 'Kannada', 'ko': 'Hangul / Han',
    'lo': 'Lao', 'ml': 'Malayalam', 'my': 'Myanmar', 'or': 'Odia',
    'pa': 'Gurmukhi', 'si': 'Sinhala', 'ta': 'Tamil', 'te': 'Telugu',
    'th': 'Thai', 'zh-Hans': 'Han (Simplified)', 'zh-Hant': 'Han (Traditional)',
}
RECENT_ENGLISH_COPIES = {'games.original', 'games.catalog', 'games.sound',
                         'games.demo_index', 'games.source_only', 'catalog.demo.polezeros.note'}


def note_key(program, english):
    """The native ProgramInfo adapters use these bounded compatibility-message families.

    Unknown prose is deliberately not accepted as a localized diagnostic.
    """
    key = 'catalog.' + program['id'] + '.note'
    if key in english:
        return key
    note = program.get('note', '')
    if note.startswith('compile error: '):
        return 'catalog.note.compile_error'
    if note.endswith('execution has not been verified on mobile.'):
        return 'catalog.note.unverified'
    if note.startswith('Original source and genuine native execution verified'):
        return 'catalog.note.verified'
    return None


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write_tsv(path, fields, rows):
    with path.open('w', encoding='utf-8', newline='') as output:
        writer = csv.DictWriter(output, fields, dialect='excel-tab', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def android_locales_check(path, aapt2, expected):
    """Resolve the compiled resource name: shrinking can rename the XML file in an APK."""
    def dump(kind, *args):
        return subprocess.check_output([str(aapt2), 'dump', kind, str(path), *args], text=True)
    resources = dump('resources')
    match = re.search(r'resource (0x[0-9a-f]+) xml/locales_config\s+\(\) \(file\) (\S+) type=XML', resources)
    if not match:
        raise ValueError('compiled xml/locales_config resource is missing')
    resource_id, resource_file = match.groups()
    compiled = re.findall(r'Raw: "([^"]+)"', dump('xmltree', '--file', resource_file))
    manifest = dump('xmltree', '--file', 'AndroidManifest.xml')
    referenced = bool(re.search(r'\blocaleConfig\([^\n]+=@' + re.escape(resource_id) + r'\b', manifest))
    return {'resource_id': resource_id, 'resource_file': resource_file,
            'declarations': compiled, 'matches_platform_source': compiled == expected,
            'referenced_by_manifest': referenced}


def package_check(path, catalogs, aapt2=None, android=None, ios=None):
    expected = [L10N / 'locales.json'] + [L10N / (c + '.json') for c in catalogs]
    expected += sorted((L10N / 'vocab').glob('*.deflate'))
    result = {'artifact': str(path), 'files_checked': 0, 'mismatches': []}
    archive = zipfile.ZipFile(path) if path.is_file() else None
    try:
        for source in expected:
            suffix = 'runtime/' + str(source.relative_to(L10N.parent))
            try:
                packaged = archive.read('assets/' + suffix) if archive else (path / suffix).read_bytes()
            except (KeyError, FileNotFoundError):
                result['mismatches'].append({'file': suffix, 'reason': 'missing'})
                continue
            result['files_checked'] += 1
            if packaged != source.read_bytes():
                result['mismatches'].append({'file': suffix, 'reason': 'bytes differ'})
        if archive:
            result['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            if aapt2:
                try:
                    locales = android_locales_check(path, aapt2, android)
                    result['compiled_locales'] = locales
                    if not locales['matches_platform_source'] or not locales['referenced_by_manifest']:
                        result['mismatches'].append({'file': 'xml/locales_config', 'reason': 'declarations or manifest reference differ'})
                except (subprocess.CalledProcessError, ValueError) as error:
                    result['mismatches'].append({'file': 'xml/locales_config', 'reason': str(error)})
        elif (path / 'Info.plist').exists():
            with (path / 'Info.plist').open('rb') as source:
                result['bundle_localizations'] = plistlib.load(source).get('CFBundleLocalizations', [])
            if ios is not None:
                actual = result['bundle_localizations']
                result['compiled_locales_match_platform_source'] = len(actual) == len(ios) and set(actual) == set(ios)
                if not result['compiled_locales_match_platform_source']:
                    result['mismatches'].append({'file': 'Info.plist', 'reason': 'compiled localization declarations differ'})
    finally:
        if archive:
            archive.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--baseline', default='ca74cb7')
    parser.add_argument('--apk', type=Path, action='append', default=[])
    parser.add_argument('--ios-app', type=Path)
    parser.add_argument('--aapt2', type=Path, help='Also verify compiled Android locale XML and its manifest reference')
    parser.add_argument('--strict-coverage', action='store_true', help='Fail on known English UI copies or unregistered app-owned metadata')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = read(L10N / 'locales.json')
    english = {k: v for k, v in read(L10N / 'en.json').items() if not k.startswith('$')}
    catalogs = {c: read(L10N / (c + '.json')) for c in sorted({l['catalog'] for l in manifest['locales']})}
    previous = json.loads(subprocess.check_output(['git', 'show', args.baseline + ':shared/runtime/l10n/en.json'], cwd=ROOT))
    with (ROOT / 'temple_os_swift/App/TempleOSMobile/Info.plist').open('rb') as source:
        ios = plistlib.load(source)['CFBundleLocalizations']
    android = [e.attrib['{http://schemas.android.com/apk/res/android}name'] for e in ET.parse(
        ROOT / 'temple_os_kotlin/app/src/main/res/xml/locales_config.xml').getroot()]
    rows, copies = [], []
    ledger = read(ROOT / 'shared/test-vectors/god-words/preserved-tokens.json')
    preserved = Counter(c for token in ledger['tokens'] for c in token['catalogs'])
    for locale in manifest['locales']:
        cat = catalogs[locale['catalog']]
        present = [k for k in english if isinstance(cat.get(k), str) and cat[k].strip()]
        missing = [k for k in english if k not in present]
        copied = [k for k in RECENT_ENGLISH_COPIES if locale['catalog'] != 'en' and cat.get(k) == english[k]]
        for key in sorted(copied):
            copies.append({'locale': locale['id'], 'catalog': locale['catalog'], 'key': key, 'value': english[key]})
        vocab = L10N / 'vocab' / (locale['catalog'] + '.deflate')
        entries = zlib.decompress(vocab.read_bytes(), -15).decode('utf-8').splitlines()[1:] if vocab.exists() else []
        rows.append({**locale, 'script_classification': SCRIPTS.get(locale['catalog'], 'Latin'),
                     'swift_system_tag': IOS_TAG.get(locale['id'], locale['id']),
                     'kotlin_system_tag': ANDROID_TAG.get(locale['id'], locale['id']),
                     'swift_declared': IOS_TAG.get(locale['id'], locale['id']) in ios,
                     'kotlin_declared': ANDROID_TAG.get(locale['id'], locale['id']) in android,
                     'registered_present': len(present), 'registered_total': len(english),
                     'registered_percent': round(len(present) * 100 / len(english), 4),
                     'missing_keys': missing, 'known_recent_english_copies': sorted(copied),
                     'native_review_flags': len(cat.get('$review', [])),
                     'vocabulary_translated': sum(bool(e) for e in entries) - preserved[locale['catalog']],
                     'vocabulary_resource_present': sum(bool(e) for e in entries),
                     'vocabulary_original_tokens_preserved': preserved[locale['catalog']],
                     'vocabulary_total': len(entries) if entries else 7569,
                     'vocabulary_status': 'English reference' if locale['catalog'] == 'en'
                     else 'localized entries plus explicitly preserved original tokens'})
    catalog = read(ROOT / 'shared/program-manifests/catalog.json')
    metadata = []
    for program in catalog['programs']:
        for field in ('description', 'note'):
            key = 'catalog.' + program['id'] + '.' + field
            if program.get(field) and key not in english:
                resolved = note_key(program, english) if field == 'note' else None
                metadata.append({'id': program['id'], 'field': field, 'missing_key': key, 'value': program[field],
                                 'resolved_key': resolved or '',
                                 'classification': 'localized compatibility frame; technical details invariant' if resolved in english
                                 else 'original source excerpt: invariant' if field == 'description' and program['id'].startswith('source.')
                                 else 'app-owned compatibility / description: localization review'})
    for group in catalog['groups']:
        if not group['id'].startswith(('dir.', 'help.')):
            key = 'catalog.group.' + group['id']
            metadata.append({'id': group['id'], 'field': 'group.title', 'missing_key': '', 'value': group['title'],
                             'resolved_key': key if key in english else '',
                             'classification': 'localized navigation heading' if key in english
                             else 'original heading' if group['id'].startswith('index.') else 'navigation heading: localization review'})
    recent = [{'key': k, 'change': 'added' if k not in previous else 'modified', 'english': v,
               'catalogs_identical_to_english': ','.join(c for c, d in catalogs.items() if c != 'en' and d.get(k) == v)}
              for k, v in english.items() if previous.get(k) != v]
    snapshot = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'baseline': args.baseline, 'resource_coverage_definition': 'nonempty registered catalog values / English registered keys',
                'language_subtags': len({l['language'] for l in manifest['locales']}),
                'locale_count': len(rows), 'catalog_count': len(catalogs), 'english_keys': len(english),
                'swift_declarations': ios, 'kotlin_declarations': android, 'locales': rows,
                'unregistered_metadata_counts': dict(Counter(x['classification'] for x in metadata)),
                'orphaned_catalogs': sorted(p.stem for p in L10N.glob('*.json') if p.stem not in catalogs and p.stem != 'locales'),
                'packages': []}
    for path in (*args.apk, args.ios_app):
        if path:
            snapshot['packages'].append(package_check(path.resolve(), catalogs, args.aapt2, android, ios))
    (args.out / 'census.json').write_text(json.dumps(snapshot, ensure_ascii=False, indent=1) + '\n')
    write_tsv(args.out / 'RECENT_STRINGS.tsv', ['key', 'change', 'english', 'catalogs_identical_to_english'], recent)
    write_tsv(args.out / 'ENGLISH_COPIES.tsv', ['locale', 'catalog', 'key', 'value'], copies)
    write_tsv(args.out / 'UNREGISTERED_METADATA.tsv', ['id', 'field', 'missing_key', 'resolved_key', 'value', 'classification'], metadata)
    print(f'{len(rows)} locales / {len(catalogs)} catalogs / {len(english)} registered keys; '
          f'{len(metadata)} metadata rows triaged; {len(copies)} locale/key English-copy findings')
    for result in snapshot['packages']:
        print(f"{result['artifact']}: {result['files_checked']} files checked; {len(result['mismatches'])} mismatches")
    incomplete = bool(copies) or any(l['missing_keys'] for l in rows) or any(
        m['classification'] in ('app-owned compatibility / description: localization review', 'navigation heading: localization review') for m in metadata)
    if args.strict_coverage and incomplete:
        print('FAIL: known untranslated UI copy / unregistered app-owned metadata remains')
    return int(any(r['mismatches'] for r in snapshot['packages']) or (args.strict_coverage and incomplete))


if __name__ == '__main__':
    sys.exit(main())
