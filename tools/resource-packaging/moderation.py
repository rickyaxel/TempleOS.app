#!/usr/bin/env python3
"""Content moderation of the bundled TempleOS files (docs/content-moderation/CONTENT_MODERATION.md).

The original files stay as Terry A. Davis wrote them in the byte-exact ISO extraction
(reference/templeos-iso, not shipped). The apps ship only the moderated copies that
build_bundled_fs.py writes into shared/bundled-fs, with these edits applied:

  moderation.json  "edits": one entry per span of an original file, located by its line and
                   byte columns in the text part (the bytes before the first NUL; embedded sprites
                   after it are never touched) and verified by the sha256 of the original bytes,
                   so the manifest never repeats the offensive text itself. "replace" is the new
                   text, or "@<marker>" for one of the visible redaction markers in "markers".

An edit whose hash does not match fails the build: a changed source can never be edited blindly.
Markers are plain ASCII without "$" (DolDoc command delimiter) and without NUL.

Usage (maintainers):
  moderation.py check <templeos-iso dir>             verify every edit against the originals
  moderation.py span <iso dir> <path> <line> <text>  print the start/end/sha256 of <text> on that line
                                                     (to write a new entry; the text is not stored)
"""
import hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, 'moderation.json')


class ModerationError(Exception):
    pass


def load(path=MANIFEST):
    m = json.load(open(path, encoding='utf-8'))
    for name, text in m['markers'].items():
        if '$' in text or '\0' in text or not text.isascii():
            raise ModerationError(f'marker {name!r} must be ASCII without "$" or NUL')
    by_path = {}
    for e in m['edits']:
        by_path.setdefault(e['path'], []).append(e)
    return m, by_path


def replacement(m, e):
    r = e['replace']
    if r.startswith('@'):
        return m['markers'][r[1:]].encode('ascii')
    b = r.encode('latin-1')
    if b'$' in b or b'\0' in b:
        raise ModerationError(f'{e["id"]}: replacement must not contain "$" or NUL')
    return b


def apply(m, edits, data, rel=''):
    """Applies [edits] to the original bytes [data]; returns the moderated bytes."""
    end = data.find(b'\0')
    text, rest = (data, b'') if end < 0 else (data[:end], data[end:])
    lines = text.split(b'\n')
    # right to left within a line, so earlier columns stay valid
    for e in sorted(edits, key=lambda e: (e['line'], e['start']), reverse=True):
        i = e['line'] - 1
        if i < 0 or i >= len(lines):
            raise ModerationError(f'{e["id"]} {rel}: no line {e["line"]}')
        ln = lines[i]
        span = ln[e['start']:e['end']]
        if hashlib.sha256(span).hexdigest() != e['sha256'] or len(span) != e['end'] - e['start']:
            raise ModerationError(f'{e["id"]} {rel}:{e["line"]}: the original text differs from the manifest (sha256 mismatch)')
        lines[i] = ln[:e['start']] + replacement(m, e) + ln[e['end']:]
    return b'\n'.join(lines) + rest


def moderate(rel, data, manifest=None):
    """(moderated bytes, changed) for bundled path [rel]."""
    m, by_path = manifest or load()
    edits = by_path.get(rel)
    if not edits:
        return data, False
    return apply(m, edits, data, rel), True


def main(argv):
    if len(argv) >= 2 and argv[0] == 'check':
        m, by_path = load()
        n = 0
        for rel, edits in sorted(by_path.items()):
            data = open(os.path.join(argv[1], rel), 'rb').read()
            apply(m, edits, data, rel)
            n += len(edits)
        print(f'{n} edits in {len(by_path)} files verified against {argv[1]}')
        return 0
    if len(argv) == 5 and argv[0] == 'span':
        data = open(os.path.join(argv[1], argv[2]), 'rb').read().split(b'\0')[0]
        ln = data.split(b'\n')[int(argv[3]) - 1]
        t = argv[4].encode('latin-1')
        s = ln.find(t)
        if s < 0 or ln.find(t, s + 1) >= 0:
            print('not found exactly once on that line'); return 1
        print(json.dumps({'line': int(argv[3]), 'start': s, 'end': s + len(t), 'sha256': hashlib.sha256(t).hexdigest()}))
        return 0
    print(__doc__); return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
