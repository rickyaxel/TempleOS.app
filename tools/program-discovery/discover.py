#!/usr/bin/env python3
"""Reconcile every RedSea manifest entry; generate mobile discovery metadata offline.

The ISO manifest, not a suffix glob or an HTML mirror, defines the scan boundary.
Classification is deliberately separate from execution approval. A tutorial link
can point to a library, an installer or an x86 experiment. None gains a Run action
merely by being discovered or successfully translated.
"""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
ORIGINAL = ROOT / 'reference/templeos-iso'
SOURCE_SUFFIXES = {'.HC', '.HH', '.IN', '.CPP', '.PRJ'}
VERSION = 'TempleOS V5.03'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text(data):
    return data.split(b'\0')[0].decode('latin1')


def top_statements(src):
    """Lexical, brace-aware evidence, not a claim to be a HolyC compiler.

    Remove comments, quoted strings and preprocessor lines before tracking braces.
    In particular calls *inside* functions never make a library standalone.
    Preserve a literal marker for HolyC's executable top-level print statements.
    """
    tokens = re.findall(r'/\*.*?\*/|//[^\n]*|^\s*#[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{};]|[^{};"\'/#]+|.', src, re.S | re.M)
    depth = 0
    pending = ''
    statements = []
    for token in tokens:
        if token.startswith(('/*', '//')) or token.lstrip().startswith('#'):
            continue
        if token.startswith(('"', "'")):
            token = ' STRING_LITERAL '
        if token == '{':
            if depth == 0:
                if re.match(r'\s*(for|while|do|if|switch|try)\b', pending):
                    statements.append(pending.strip() + ' {...}')
                pending = ''
            depth += 1
        elif token == '}':
            depth = max(0, depth - 1)
            if depth == 0:
                pending = ''
        elif depth == 0:
            if token == ';':
                s = ' '.join(pending.split())
                if s and (re.match(r'^(?:STRING_LITERAL|for\b|while\b|do\b)', s) or
                          re.match(r'^[A-Za-z_]\w*\s*(?:\(|$)', s)):
                    # A declaration/prototype starts with a type and another name.
                    if s.startswith('STRING_LITERAL') or not re.match(r'^(?:public\s+|extern\s+)?(?:U0|[IU][0-9]+|F64|Bool|class|union|[A-Z]\w*)\s+\**[A-Za-z_]\w*', s):
                        statements.append(s)
                pending = ''
            else:
                pending += token
    return statements


def resolve(path, base, names):
    path = path.removesuffix('.Z')
    if path.startswith(('::/', 'C:/')):
        path = path[3:]
    elif path.startswith('~/'):
        path = 'Home/' + path[2:]
    elif path.startswith('/'):
        path = path[1:]
    else:
        path = str(Path(base).parent / path)
    # Normalize without escaping the distribution.
    parts = []
    for p in path.split('/'):
        if p == '..':
            if not parts:
                return None
            parts.pop()
        elif p not in ('', '.'):
            parts.append(p)
    path = '/'.join(parts)
    for suffix in ('', '.HC', '.HH', '.DD'):
        match = names.get((path + suffix).lower())
        if match:
            return 'C:/' + match
    return None


def demo_index(src, names):
    groups = []
    group = None
    for line in src.splitlines():
        match = re.search(r'\$TR,"([^"]+)"', line)
        if match:
            group = {'id': 'index.' + str(len(groups)), 'title': match[1], 'entries': [],
                     'source': 'C:/Doc/DemoIndex.DD', 'presentation': 'links'}
            groups.append(group)
        if group is None:
            continue
        for ref in re.finditer(r'\$(LK|MA)[^$]*?"([^"$]+)"[^$]*\$', line):
            label = ref[2]
            if not label.startswith('::/'):
                # Symbol references remain references, never fabricated include paths.
                a = re.search(r'A="MN:([^"]+)"', ref[0])
                if a:
                    group['entries'].append({'symbol': a[1], 'label': label})
                continue
            path = resolve(label, 'Doc/DemoIndex.DD', names)
            directory = label[3:].removesuffix('/')
            group['entries'].append({'path': path or 'C:/' + directory,
                                     'directory': path is None, 'label': label[3:]})
    return groups


def discover(shared, approved):
    shared = Path(shared).resolve()
    mf = json.loads((ORIGINAL / 'MANIFEST.json').read_text())
    paths = sorted(mf['files'])
    names = {p.lower(): p for p in paths}
    assert len(names) == len(paths), 'case-colliding ISO paths'
    raw = {}
    for path in paths:
        data = (ORIGINAL / path).read_bytes()
        assert digest(data) == mf['files'][path]['sha256'], 'modified extraction: ' + path
        raw[path] = data
    sources = {p: text(b) for p, b in raw.items() if Path(p).suffix in SOURCE_SUFFIXES or p.endswith('.DD')}
    index = demo_index(sources['Doc/DemoIndex.DD'], names)
    indexed = defaultdict(list)
    for g in index:
        for e in g['entries']:
            if 'path' in e:
                indexed[e['path']].append(g['title'])
    native = {p['path']: p for p in json.loads((shared / 'native-translation/manifest.json').read_text())['sources']}
    baseline = {p['path']: p for p in approved}
    includes = {}
    reverse = defaultdict(list)
    references = defaultdict(list)
    menus = []
    help_indexes = defaultdict(list)
    for p, src in sources.items():
        deps = []
        for inc in re.findall(r'^\s*#include\s+"([^"]+)"', src, re.M):
            target = resolve(inc, p, names)
            deps.append({'expression': inc, 'resolved': target})
            if target:
                reverse[target].append('C:/' + p)
        includes['C:/' + p] = deps
        for ref in re.findall(r'(?:::|C:)/[^"$\s\\,;()]+', src):
            target = resolve(ref, p, names)
            if target and target != 'C:/' + p:
                references[target].append('C:/' + p)
        for hi in re.findall(r'^\s*#help_index\s+"([^"]*)"', src, re.M):
            for title in hi.split(';'):
                if title:
                    help_indexes[title].append('C:/' + p)
        # Record every document containing actionable menu markup and source menu API.
        primitives = sorted(set(re.findall(r'\$(SP[^,$]*|MA[^,$]*|MU|BT|TR)[,$]|\b(MenuPush|DocMenu|PopUpMenu)\s*\(', src)))
        if primitives:
            menus.append({'path': 'C:/' + p, 'primitives': sorted({a or b for a, b in primitives}),
                          'headings': re.findall(r'\$TR,"([^"]+)"', src),
                          'kind': 'document' if p.endswith('.DD') else 'source'})

    def closure(path, seen=None):
        seen = set() if seen is None else seen
        for dep in includes.get(path, []):
            target = dep['resolved']
            if target and target not in seen:
                seen.add(target)
                closure(target, seen)
        return sorted(seen - {path})

    rows = []
    additions = []
    for rel in paths:
        path = 'C:/' + rel
        src = sources.get(rel, '')
        ext = Path(rel).suffix
        old = baseline.get(path)
        statements = top_statements(src) if ext == '.HC' else []
        role = 'data'
        evidence = []
        if ext == '.DD' or ext == '.TXT':
            role = 'document'
        elif ext in SOURCE_SUFFIXES:
            role = 'system-internal' if rel.startswith(('Adam/', 'Kernel/', 'Compiler/')) else 'source-dependency'
            if rel.startswith('Downloads/Linux/'):
                role = 'host-tool'
            elif rel.startswith('Misc/') or rel.startswith(('StartOS.', 'MakeHome.', 'Home', 'Once.')):
                role = 'system-installation' if not rel.startswith('HomeWrappers.') else 'command-library'
            elif rel.startswith('Apps/'):
                if '/Examples/' in rel and statements:
                    role = 'song'
                elif Path(rel).name == 'Run.HC' or path == 'C:/Apps/TimeClock/Load.HC':
                    role = 'application'
                elif Path(rel).name == 'Install.HC':
                    role = 'installer'
            elif rel.startswith('Demo/'):
                if rel.startswith('Demo/AcctExample/'):
                    role = 'account-configuration-example'
                elif rel.startswith('Demo/Templates/'):
                    role = 'template'
                elif rel.endswith('StadiumGen.HC'):
                    role = 'asset-generator'
                elif statements:
                    role = 'standalone-demo'
                elif path in indexed or not reverse.get(path):
                    role = 'source-example'
            elif rel.startswith('Doc/'):
                role = 'documentation-tool'
            evidence = statements[:12]
        if rel.startswith('Downloads/Linux/'):
            role='host-tool' if Path(rel).name in {'TOSZ','TOSZ.CPP','gw'} else 'host-build-script'
        if rel.startswith('0000Boot/'):
            role='boot-image'
        elif ext in {'.BIN','.MAP','.PRJ'}:
            role='build-artifact'
        if rel.startswith('Misc/Tour/'):
            role='input-tour' if rel=='Misc/Tour/Tour.IN' else 'input-tour-dependency'
        if old:
            evidence.insert(0, 'Existing reviewed catalog: ' + old['id'])
            if rel.startswith('Demo/'):
                role = 'standalone-demo'
        bundled = shared / 'bundled-fs' / rel
        n = native.get(path, {})
        functions = re.findall(r'(?m)^public\s+[\w*]+\s+\**(\w+)\s*\(', src)
        if role == 'system-internal' and rel.startswith('Adam/') and functions:
            role = 'command-library' if any(t in src for t in ['#help_index "Cmd Line', '#help_index "Info', '#help_index "File/Cmd']) or rel.startswith('Adam/Opt/Utils/') else role
        relevant = role in {'application', 'song', 'standalone-demo', 'source-example', 'template', 'asset-generator', 'command-library', 'system-installation', 'host-tool', 'documentation-tool','input-tour'}
        missing = None
        if relevant and not old:
            missing = 'excluded from build_catalog.py fixed allowlists' if bundled.is_file() else 'excluded by the existing bundled filesystem policy'
        dependencies = sorted(set(closure(path)) | (set(n.get('closure', {})) - {path}))
        if rel == 'Demo/Games/Stadium/Stadium.HC':
            dependencies.append('C:/Demo/Games/Stadium/StadiumBG.GR')
        if rel=='Misc/Tour/Tour.IN':
            dependencies += ['C:/Misc/Tour/Tour%X.IN'%i for i in range(1,13)]
        dynamic = re.findall(r'\b(?:FileRead|GRRead|DocRead|DirMk|RegRead|RegWrite|FileWrite|Cd|PlayerPick|ExeFile|InFile)\s*\(([^\n;]{0,180})', src)
        row = dict(path=path, role=role, sourceVersion=VERSION, sha256=mf['files'][rel]['sha256'],
                   bytes=len(raw[rel]), compressedOnISO=mf['files'][rel]['compressed_on_iso'],
                   bundled=bundled.is_file(), bundleSHA256=digest(bundled.read_bytes()) if bundled.is_file() else None,
                   demoIndex=indexed.get(path, []), referencedBy=sorted(set(references[path])),
                   includedBy=sorted(set(reverse[path])), includes=includes.get(path, []),
                   dependencies=dependencies, publicFunctions=functions, entryEvidence=evidence,
                   dynamicFileExpressions=dynamic, nativeTranslation=n.get('status', 'not evaluated'),
                   compileDiagnostic=n.get('detail', ''), previouslyRegistered=old is not None,
                   omissionCause=missing, relevantPresentation=relevant)
        row['animationEvidence'] = dict(drawCallbacks=re.findall(r'\bdraw_it\s*=\s*&?(\w+)',src),
            sleeps=re.findall(r'\bSleep\s*\(([^\n;]{0,100}?)\)',src),
            timingFunctions=sorted(set(re.findall(r'\b(FullTri|FullSaw|Caw|tS|tSUnix|GetTSC|cnts|Jiffies)\b',src))),
            lifecycle=sorted(set(re.findall(r'\b(SettingsPush|SettingsPop|MenuPush|MenuPop|Spawn|Kill|SndTaskEndCB)\b',src))))
        rows.append(row)
        # No helper is promoted to an executable tile. Source examples are deliberately
        # visible with an inspect-only state, including hardware and installation demos.
        if relevant and not old and bundled.is_file():
            pid = 'source.' + rel.lower().replace('/', '.').rsplit('.', 1)[0]
            title = Path(rel).stem
            additions.append(dict(id=pid, title=title, category='discovery', path=path,
                                  kind='interpreted_holyc', author='Terry A. Davis',
                                  license='Public domain (TempleOS)', source=VERSION + ' ISO',
                                  controls=[], capabilities=['console'], orientation='any', minRuntime=1,
                                  description=(src.splitlines()[0].removeprefix('//').strip() if src.startswith('//') else '')[:160],
                                  status='unsupported',
                                  note=(n.get('detail') or ('Original ' + role + '; execution has not been verified on mobile.')),
                                  discoveryRole=role, discoveryEvidence=evidence,
                                  historicalTitle=title))
    groups = []

    def group(gid, title, parent='programs', **extra):
        g = dict(id=gid, title=title, parent=parent, programIds=[], presentation='links', **extra)
        groups.append(g)
        return g

    group('programs', 'Programs', '', source='Mobile navigation over original indexes')
    apps = group('applications', 'Applications', source='C:/Apps', directory='C:/Apps')
    demos = group('demos', 'Demo Index', source='C:/Doc/DemoIndex.DD', document='C:/Doc/DemoIndex.DD')
    folders = group('demo.folders', 'Demo directories', source='C:/Demo', directory='C:/Demo')
    tools = group('tools', 'Commands and utilities', source='C:/Doc/HelpIndex.DD', document='C:/Doc/HelpIndex.DD')
    docs = group('documents', 'Documentation', source='C:/Doc', directory='C:/Doc', document='C:/Doc/HelpIndex.DD')
    group('distribution', 'Original filesystem', source='C:/', directory='C:/')
    all_progs = approved + additions
    bypath = {p['path']: p for p in all_progs}
    for p in all_progs:
        if p['path'].startswith('C:/Apps/') and '/Examples/' not in p['path']:
            apps['programIds'].append(p['id'])
        if p['path'].startswith('C:/Misc/') or p.get('discoveryRole') in {'command-library', 'system-installation', 'documentation-tool'}:
            tools['programIds'].append(p['id'])
    apps['programIds'].sort(key=lambda pid:next((str(Path(p['path']).parent).lower(),p['path'].endswith('/Load.HC'),p['path'].lower()) for p in all_progs if p['id']==pid))
    group('songs', 'Psalmody Examples', 'applications', source='C:/Apps/Psalmody/Examples',
          directory='C:/Apps/Psalmody/Examples')['programIds'] = [p['id'] for p in all_progs if '/Apps/Psalmody/Examples/' in p['path']]
    group('tour','Take Tour','tools',source='C:/Misc/Tour/Tour.IN',directory='C:/Misc/Tour')['programIds'] = [p['id'] for p in all_progs if p['path']=='C:/Misc/Tour/Tour.IN']
    group('host.tools','Linux distribution tools','tools',source='C:/Downloads/Linux',document='C:/Doc/TOSZ.DD')['references'] = [
        dict(path='C:/Downloads/Linux/'+name,label=name,directory=False,available=False)
        for name in ['TOSZ','TOSZ.CPP','gw','make_tosz']]
    for g in index:
        entries = []
        ids = []
        for e in g['entries']:
            p = bypath.get(e.get('path'))
            if not p and e.get('directory'):
                folder = e['path'] + '/'
                p = next((p for p in all_progs if p['path'].startswith(folder) and p['path'].endswith('/Run.HC')), None)
            if p and p['id'] not in ids:
                ids.append(p['id'])
            else:
                entries.append(e)
        groups.append(dict(g, parent='demos', programIds=ids, references=entries))
    for d in sorted({str(Path(p).parent) for p in paths if p.startswith('Demo/')}):
        # Nested package folders remain packages (Stadium), not dozens of apps.
        ids = [p['id'] for p in sorted(all_progs,key=lambda p:p['path'].lower()) if str(Path(p['path'][3:]).parent) == d]
        group('dir.' + d.lower().replace('/', '.'), '/' + d, 'demo.folders', source='C:/' + d,
              directory='C:/' + d)['programIds'] = ids
    group('help', 'Original help index', 'tools', source='C:/Doc/HelpIndex.DD', document='C:/Doc/HelpIndex.DD')
    titles = set(help_indexes)
    for title in list(titles):
        parts = title.split('/')
        titles.update('/'.join(parts[:i]) for i in range(1, len(parts)))
    def help_id(title):
        return 'help.' + digest(title.encode())[:16]
    for title in sorted(titles):
        help_paths = list(dict.fromkeys(help_indexes.get(title, [])))
        parent = title.rsplit('/', 1)[0] if '/' in title else ''
        g = group(help_id(title), title.rsplit('/', 1)[-1], help_id(parent) if parent else 'help', source='#help_index ' + title)
        g['references'] = [{'path': p, 'label': p[3:], 'directory': False, 'available':(shared / 'bundled-fs' / p[3:]).is_file()} for p in help_paths]
    # A source-defined symbol reference resolves to its actual source, without
    # inventing a runnable include for a function that requires arguments/globals.
    for g in groups:
        for ref in g.get('references', []):
            if 'symbol' in ref:
                symbol = ref['symbol']
                found = next((p for p, s in sources.items() if re.search(r'\b' + re.escape(symbol) + r'\s*\([^;{}]*\)\s*\{', s)), None)
                if found:
                    ref['path'] = 'C:/' + found
    summary = dict(sourceVersion=VERSION, isoSHA256=mf['iso_sha256'], directoriesScanned=len(mf['dirs']),
                   filesExamined=len(raw), sourceFilesExamined=sum(Path(p).suffix in SOURCE_SUFFIXES for p in raw),
                   holyCFilesExamined=sum(p.endswith('.HC') for p in raw),
                   menuDocuments=sum(m['kind'] == 'document' for m in menus), menuDefinitions=len(menus),
                   demoIndexGroups=len(index), personalMenuGroups=4, helpIndexGroups=len(help_indexes),
                   roles=dict(sorted(Counter(r['role'] for r in rows).items())),
                   candidates=sum(r['relevantPresentation'] for r in rows),
                   standalonePrograms=sum(r['role'] in {'standalone-demo', 'application', 'song'} for r in rows),
                   presentationsAdded=len(additions), initialUnverifiedPresentations=len(additions), previousCatalogPrograms=len(approved),
                   missingSwift=len(additions), missingKotlin=len(additions))
    return dict(version=1, summary=summary, directories=sorted(mf['dirs']), files=rows,
                menuDefinitions=menus, demoIndex=index, helpIndexes=dict(sorted(help_indexes.items())),
                additions=additions, groups=groups)


if __name__ == '__main__':
    shared = ROOT / 'shared'
    base = json.loads((ROOT / 'docs/distribution-audit/baseline-catalog.json').read_text())['programs']
    data = discover(shared, base)
    dest = ROOT / 'docs/distribution-audit/distribution.json'
    dest.write_text(json.dumps(data, indent=1) + '\n')
    print(json.dumps(data['summary'], indent=1))
