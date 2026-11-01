#!/usr/bin/env python3
"""Compare built simulator bundles with canonical metadata, runtime assets and catalog sources."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ios_app', type=Path)
    parser.add_argument('android_apk', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    shared = ROOT / 'shared'
    catalog = json.loads((shared / 'program-manifests/catalog.json').read_text())
    files = [(shared / 'program-manifests/catalog.json', 'catalog.json', 'assets/catalog.json')]
    for path in sorted((shared / 'runtime').rglob('*')):
        if path.is_file() and not path.name.startswith('.'):
            rel = path.relative_to(shared / 'runtime').as_posix()
            files.append((path, 'runtime/' + rel, 'assets/runtime/' + rel))
    sources = set()
    unavailable = set()
    for program in catalog['programs']:
        sources.add(program['path'])
        sources.update(program['dependencies'])
        if program['status'] == 'unsupported':
            unavailable.update(program.get('missingDependencies', []))
        else:
            assert not program.get('missingDependencies'), program['id']
    missing = {source for source in sources if not (shared / 'bundled-fs' / source[3:]).is_file()}
    assert missing <= unavailable, sorted(missing - unavailable)
    sources -= missing
    for source in sorted(sources):
        assert source.startswith('C:/'), source
        rel = source[3:]
        files.append((shared / 'bundled-fs' / rel, 'bundled-fs/' + rel, 'assets/fs/' + rel))
    rows = []
    with zipfile.ZipFile(args.android_apk) as archive:
        for path, ios, android in files:
            data = path.read_bytes()
            assert (args.ios_app / ios).read_bytes() == data, ios
            assert archive.read(android) == data, android
            rows.append(dict(file=path.relative_to(ROOT).as_posix(), bytes=len(data),
                             sha256=hashlib.sha256(data).hexdigest(), ios=True, android=True))
    report = dict(files=len(rows), bytesCompared=sum(row['bytes'] for row in rows),
                  catalogPrograms=len(catalog['programs']), sourcesAndDependencies=len(sources),
                  sourceOnlyUnavailableDependencies=sorted(missing), rows=rows)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'rows'}))


if __name__ == '__main__':
    main()
