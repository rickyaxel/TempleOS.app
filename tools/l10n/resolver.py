#!/usr/bin/env python3
"""Reference UI-locale resolver for TempleOS Mobile (docs/localization.md).

Same contract as the Kotlin (core/l10n/LocaleResolver.kt) and Swift
(TempleCore/L10n/LocaleResolver.swift) implementations; all three run the shared vectors in
shared/test-vectors/l10n/resolver_vectors.json.

Adapted from an earlier resolver by the same author,
with one deliberate difference: TempleOS Mobile never uses geography. The only "country" input
is the device's own region setting, and it is used only to choose a member of a language family
(bare `fr` on a device set to Canada -> fr-CA). There are no region/country default steps:
after the explicit choice and the device's preferred languages comes en-US.

Usage: resolver.py --make-vectors REFERENCE.json   (regenerates the shared vectors from a reference set)
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(ROOT, 'shared/runtime/l10n/locales.json')


class Resolver:
    def __init__(self, manifest):
        self.default = manifest['default_locale']
        self.locales = manifest['locales']
        self.input_tag = re.compile(manifest['input_tag'])
        self.countries = manifest['countries']
        self.ids = {l['id'].lower(): l['id'] for l in self.locales}
        fam_scripts = set(manifest['family_scripts'])
        groups = {}
        for l in self.locales:
            key = l['language'] + ('-' + l['script'] if l['script'] else '')
            groups.setdefault(key.lower(), []).append(l)
            if l['language'] in fam_scripts:
                groups.setdefault(l['language'], []).append(l)
        self.families = {}
        for key, members in groups.items():
            defaults = [m['id'] for m in members if m['family_default']]
            self.families[key] = ([m['id'] for m in members], None if key in fam_scripts else (defaults[0] if defaults else None))
        items = [(k, 'family', k) for k in self.families]
        for l in self.locales:
            for tag in [l['id']] + l['aliases']:
                if tag.lower() not in self.families:
                    items.append((tag.lower(), 'locale', l['id']))
        items += [(x.lower(), 'exclude', None) for x in manifest['exclusions']]
        self.prefixes = sorted(items, key=lambda i: (-len(i[0]), i[0]))

    @staticmethod
    def tag_region(tag):
        for part in tag.split('-')[1:]:
            if len(part) == 2 and part.isalpha():
                return part.upper()
            if len(part) == 3 and part.isdigit():
                return None
        return None

    def match(self, value, device_region=None):
        if not isinstance(value, str):
            return None
        tag = value.strip(' \t\r\n').replace('_', '-').lower()
        if not self.input_tag.fullmatch(tag):
            return None
        if tag in self.ids:
            return self.ids[tag]
        region = device_region.upper() if isinstance(device_region, str) and re.fullmatch(r'[A-Za-z]{2}', device_region) else None
        for prefix, kind, target in self.prefixes:
            if tag == prefix or tag.startswith(prefix + '-'):
                if kind == 'locale':
                    return target
                if kind == 'exclude':
                    return None
                members, default = self.families[target]
                for hint in (self.tag_region(tag), region):
                    for candidate in self.countries.get(hint, []) if hint else []:
                        if candidate in members:
                            return candidate
                return default
        return None

    def resolve(self, manual=None, preferred=(), device_region=None):
        """(locale id, source): manual -> first supported preferred language -> en-US."""
        found = self.match(manual, device_region)
        if found:
            return found, 'manual'
        for value in preferred or ():
            found = self.match(value, device_region)
            if found:
                return found, 'preferred'
        return self.default, 'default'


def load():
    return Resolver(json.load(open(MANIFEST, encoding='utf-8')))


def make_vectors(reference):
    ref = json.load(open(reference))
    r = load()
    out = []
    for v in ref['vectors']:
        manual = v.get('manual') or v.get('stored')
        expected, source = v['expected'], v['source']
        note = None
        if source in ('region', 'country', 'country_fallback'):
            expected, source = r.default, 'default'
            note = 'reference used geography; TempleOS never does'
        elif source == 'stored':
            source = 'manual'
        got = r.resolve(manual, v.get('preferred', []), v.get('country'))
        if got != (expected, source):
            raise SystemExit(f"{v['name']}: TempleOS resolver returns {got}, expected {(expected, source)}")
        item = {'name': v['name'], 'device_region': v.get('country'), 'preferred': v.get('preferred', []),
                'manual': manual, 'expected': expected, 'source': source}
        if note:
            item['note'] = note
        out.append(item)
    extra = [
        {'name': 'Spanish Spain device', 'device_region': 'ES', 'preferred': ['es-ES'], 'manual': None, 'expected': 'es-ES', 'source': 'preferred'},
        {'name': 'Spanish Mexico device', 'device_region': 'MX', 'preferred': ['es-MX'], 'manual': None, 'expected': 'es-MX', 'source': 'preferred'},
        {'name': 'Brazilian Portuguese', 'device_region': 'BR', 'preferred': ['pt-BR'], 'manual': None, 'expected': 'pt-BR', 'source': 'preferred'},
        {'name': 'Traditional Chinese script tag', 'device_region': None, 'preferred': ['zh-Hant'], 'manual': None, 'expected': 'zh-TW', 'source': 'preferred'},
        {'name': 'Simplified Chinese script tag', 'device_region': None, 'preferred': ['zh-Hans'], 'manual': None, 'expected': 'zh-CN', 'source': 'preferred'},
        {'name': 'Bare zh without region is not guessed', 'device_region': None, 'preferred': ['zh', 'ja-JP'], 'manual': None, 'expected': 'ja-JP', 'source': 'preferred'},
        {'name': 'Serbian Latin is excluded', 'device_region': 'RS', 'preferred': ['sr-Latn-RS', 'de-DE'], 'manual': None, 'expected': 'de-DE', 'source': 'preferred'},
        {'name': 'Serbian Cyrillic', 'device_region': 'RS', 'preferred': ['sr-Cyrl-RS'], 'manual': None, 'expected': 'sr', 'source': 'preferred'},
        {'name': 'iOS calendar extension', 'device_region': 'JP', 'preferred': ['ja-JP-u-ca-japanese'], 'manual': None, 'expected': 'ja-JP', 'source': 'preferred'},
        {'name': 'Unsupported then supported', 'device_region': 'GB', 'preferred': ['cy-GB', 'ga-IE', 'fr-FR'], 'manual': None, 'expected': 'fr-FR', 'source': 'preferred'},
        {'name': 'Nothing supported is English', 'device_region': 'GB', 'preferred': ['cy-GB', 'gd'], 'manual': None, 'expected': 'en-US', 'source': 'default'},
        {'name': 'Empty list', 'device_region': None, 'preferred': [], 'manual': None, 'expected': 'en-US', 'source': 'default'},
        {'name': 'Malformed tags are skipped', 'device_region': None, 'preferred': ['', '!!', 'english', 'de_AT'], 'manual': None, 'expected': 'de-DE', 'source': 'preferred'},
        {'name': 'Manual beats device', 'device_region': 'FR', 'preferred': ['fr-FR'], 'manual': 'ja-JP', 'expected': 'ja-JP', 'source': 'manual'},
        {'name': 'Invalid persisted choice falls back to device', 'device_region': 'FR', 'preferred': ['fr-FR'], 'manual': 'xx-YY', 'expected': 'fr-FR', 'source': 'preferred'},
        {'name': 'Legacy persisted catalog tag', 'device_region': None, 'preferred': [], 'manual': 'zh-Hant', 'expected': 'zh-TW', 'source': 'manual'},
        {'name': 'Hebrew legacy code', 'device_region': None, 'preferred': ['iw-IL'], 'manual': None, 'expected': 'he-IL', 'source': 'preferred'},
        {'name': 'Arabic', 'device_region': 'EG', 'preferred': ['ar-EG'], 'manual': None, 'expected': 'ar', 'source': 'preferred'},
        {'name': 'Two-letter prefix is not a match', 'device_region': None, 'preferred': ['ms-Arab'], 'manual': None, 'expected': 'en-US', 'source': 'default'},
    ]
    names = {v['name'] for v in out}
    for v in extra:
        got = r.resolve(v['manual'], v['preferred'], v['device_region'])
        if got != (v['expected'], v['source']):
            raise SystemExit(f"{v['name']}: TempleOS resolver returns {got}")
        assert v['name'] not in names
        out.append(v)
    path = os.path.join(ROOT, 'shared/test-vectors/l10n/resolver_vectors.json')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump({'schema': 1, 'description': 'TempleOS Mobile UI-locale resolution vectors (tools/l10n/resolver.py). '
               'Derived from a reference vector set, with geography removed, plus TempleOS cases.',
               'vectors': out}, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'{len(out)} vectors ({sum(1 for v in out if v.get("note"))} rewritten: geography)')


if __name__ == '__main__':
    if '--make-vectors' in sys.argv:
        make_vectors(sys.argv[sys.argv.index('--make-vectors') + 1])
