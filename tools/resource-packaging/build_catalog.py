#!/usr/bin/env python3
"""Generate shared/program-manifests/catalog.json - the bundled program registry.

Each entry describes how to launch a bundled program and what it needs; the
apps read it at startup (it is the "application registry"). Controls are
inferred from the original source (mouse, arrow keys, menus) so the mobile UI
can offer suitable touch controls.

Usage: build_catalog.py <shared dir>
"""
import hashlib, json, os, re, sys, copy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'program-discovery'))
from discover import discover
from menus import inventory as menu_inventory

TERRY = ('Terry A. Davis', 'Public domain (TempleOS)', 'TempleOS V5.03 ISO')
OURS = ('TempleOS.app contributors', 'Same license as the TempleOS.app project', 'TempleOS.app')

GAMES = ['BattleLines', 'BigGuns', 'BlackDiamond', 'BomberGolf', 'CastleFrankenstein', 'CharDemo',
         'CircleTrace', 'Collision', 'Digits', 'DunGen', 'ElephantWalk', 'FlapBat', 'FlatTops', 'Halogen',
         'MassSpring', 'Maze', 'RainDrops', 'RawHide', 'Rocket', 'RocketScience', 'Squirt', 'Talons',
         'TheDead', 'TicTacToe', 'TreeCheckers', 'Varoom', 'Wenceslas', 'Whap', 'Zing', 'ZoneOut']
APPS = ['Titanium', 'ToTheFront', 'X-Caliber', 'KeepAway', 'Strut', 'Logic', 'Psalmody', 'GrModels', 'Span',
        'Vocabulary', 'Budget']
APP_CATEGORY = {'Titanium': 'game', 'ToTheFront': 'game', 'X-Caliber': 'game', 'KeepAway': 'game',
                'Strut': 'game', 'Logic': 'app', 'Psalmody': 'app', 'GrModels': 'demo', 'Span': 'app',
                'Vocabulary': 'app', 'Budget': 'app'}
DEMOS = ['Lines', 'Bounce', 'Box', 'Palette', 'Life', 'Hanoi', 'Doodle', 'NetOfDots', 'Speedline', 'Symmetry',
         'SpritePlot3D', 'SunMoon', 'Shading', 'Shadow', 'RotateTank', '3DPoly', 'Elephant', 'BSpline',
         'Blot', 'Cartesian', 'CommonAncestor', 'MouseDemo', 'WallPaperFish', 'Lattice', 'PredatorPrey',
         'LowPassFilter', 'Collision', 'Balloon', 'Transform', 'Slider', 'Grid', 'CharAnimation', 'PanText',
         'Extents', 'LightTable', 'Pick', 'Pick3D', 'PoleZeros', 'ScrollBars', 'SpritePut', 'SpriteRaw',
         'SpriteText', 'SpritePlot', 'SpritePutExt', 'ScrnCapture', 'WallPaperCtrl', 'WinZBuf', 'FontEd', 'EdSprite', 'MathAudioDemo', 'Speedline']
EXAMPLE_DESC = {
    'Hello': 'Printing text and DolDoc colors.', 'Arithmetic': '64-bit integer math and HolyC operator precedence.',
    'Loops': 'Loops, chained comparisons and switch ranges.', 'Functions': 'Default arguments and recursion.',
    'Graphics': 'Lines, circles and text with the TempleOS graphics library.', 'Palette': 'The 16 TempleOS colors.',
    'Sound': 'Notes with Snd() and Play().', 'Animation': 'A draw_it callback animation.',
    'CatchGame': 'A small game: catch the falling stars.',
}
EXAMPLES = ['Hello', 'Arithmetic', 'Loops', 'Functions', 'Graphics', 'Palette', 'Sound', 'Animation', 'CatchGame']


def controls(src):
    c = []
    if re.search(r'ms\.(lb|rb|pos)', src) or 'MSG_MS_' in src:
        c.append('mouse')
    if 'SC_CURSOR' in src:
        c.append('arrows')
    if 'MenuPush' in src:
        c.append('menu')
    if re.search(r"GetChar|ScanChar|GetKey|ScanKey|GetMsg|ScanMsg", src):
        c.append('keyboard')
    return c


# Inputs a phone lacks that a program needs, found by the fidelity audit
# (docs/fidelity-audit/TEMPLEOS_KEYBOARD_INPUT_AUDIT.md). The apps add on-screen buttons for them.
#   wheel: reads ms.pos.z (BattleLines.HC: the command force; MsSet(,,25) at start)
#   ctrl:  a held CTRL key: Titanium.HC Bt(kbd.down_bitmap,SC_CTRL); X-Caliber.HC CTRL+arrows fire
#          missiles; CTRL + left drag scrolls the window (Adam/WinMgr.HC grab scroll), the only way
#          to see the rest of the map in RawHide (the corral), BigGuns, FlatTops and CommonAncestor
#   shift: a held SHIFT key: X-Caliber.HC SHIFT+arrows set fuse and shot size
EXTRA_CONTROLS = {
    'BattleLines': ['wheel'],
    'Titanium': ['ctrl'],
    'X-Caliber': ['ctrl', 'shift'],
    'RawHide': ['ctrl'], 'BigGuns': ['ctrl'], 'FlatTops': ['ctrl'], 'CommonAncestor': ['ctrl'],
}

# Instruments read the whole PC keyboard (including held key-up/down), rather
# than a game's few action buttons. Keep the same launch policy in both clients.
FULL_KEYBOARD = {'sound.asciiorgan', 'sound.morsecode', 'app.psalmody', 'original.jukebox', 'source.demo.keybitmap'}


def caps(src):
    k = ['console']
    if re.search(r'DCAlias|draw_it|GrPlot|Sprite3|TextPrint|gr\.', src):
        k.append('graphics')
    if re.search(r'\bSnd\b|Play\(|Beep|Noise\(|Sweep\(', src):
        k.append('sound')
    if re.search(r'FileWrite|RegWrite|RegDft', src):
        k.append('files')
    return k


def first_comment(src):
    m = re.search(r'^\s*//([^\n$]{8,80})', src, re.M)
    if m:
        t = m.group(1).strip()
        if not t.lower().startswith('see '):
            return t
    return ''


def read(shared, path):
    p = os.path.join(shared, 'bundled-fs', path[3:])
    return open(p, 'rb').read().split(b'\0')[0].decode('latin-1') if os.path.exists(p) else None


def main(shared):
    progs = []

    def add(pid, title, cat, path, who, extra_src=None, desc=None):
        src = read(shared, path)
        if src is None:
            print('missing', path)
            return
        all_src = src + (extra_src or '')
        author, lic, origin = who
        progs.append({
            'id': pid, 'title': title, 'category': cat, 'path': path,
            'kind': 'interpreted_holyc', 'author': author, 'license': lic, 'source': origin,
            'controls': controls(all_src) + EXTRA_CONTROLS.get(title, []), 'capabilities': caps(all_src),
            'orientation': 'landscape' if 'graphics' in caps(all_src) else 'any',
            'minRuntime': 1,
            'description': desc or '',
        })

    for g in GAMES:
        add('game.' + g.lower(), g, 'game', f'C:/Demo/Games/{g}.HC', TERRY)
    for a in APPS:
        d = os.path.join(shared, 'bundled-fs', 'Apps', a)
        extra = ''.join(open(os.path.join(d, f), 'rb').read().split(b'\0')[0].decode('latin-1')
                        for f in sorted(os.listdir(d)) if f.endswith('.HC'))
        add('app.' + a.lower(), a, APP_CATEGORY[a], f'C:/Apps/{a}/Run.HC', TERRY, extra)
    seen = set()
    for dm in DEMOS:
        if dm in seen:
            continue
        seen.add(dm)
        add('demo.' + dm.lower(), dm, 'demo', f'C:/Demo/Graphics/{dm}.HC', TERRY)
    for snd in ['WaterFowl', 'ASCIIOrgan', 'OhGreat', 'MorseCode']:
        add('sound.' + snd.lower(), snd, 'sound', f'C:/Demo/Snd/{snd}.HC', TERRY)
    add('original.jukebox', 'JukeBox', 'sound', 'C:/Apps/Psalmody/Load.HC', TERRY)
    add('game.stadium', 'Stadium', 'game', 'C:/Demo/Games/Stadium/Stadium.HC', TERRY)
    add('app.timeclock', 'TimeClock', 'app', 'C:/Apps/TimeClock/Load.HC', TERRY)
    for e in EXAMPLES:
        add('example.' + e.lower(), e, 'example', f'C:/Home/Examples/{e}.HC', OURS, desc=EXAMPLE_DESC.get(e, ''))
    # Existing IDs are compatibility identities, not a discovery boundary. Every
    # original file is reconciled by the ISO-backed build-time scanner.
    distribution = discover(shared, progs)
    progs.extend(copy.deepcopy(distribution['additions']))
    for p in progs:
        if not p.get('discoveryRole'):continue
        src = read(shared, p['path']) or ''
        p['controls'] = controls(src)
        p['capabilities'] = caps(src)
    compat_path = os.path.join(shared, 'program-manifests', 'compatibility.json')
    compat = json.load(open(compat_path)) if os.path.exists(compat_path) else {}
    for p in progs:
        c = compat.get(p['id'], {})
        p['status'] = c.get('status', p.get('status', 'runs'))
        p['note'] = c.get('note', p.get('note', ''))
    menu_file = os.path.join(shared, 'runtime/games-menu/menu.json')
    menu = json.load(open(menu_file))['entries'] if os.path.exists(menu_file) else []
    demo_index = read(shared, 'C:/Doc/DemoIndex.DD') or ''
    levels = {}
    directory_levels = {}
    level = ''
    for line in demo_index.splitlines():
        match = re.search(r'\$TR,"([^"]+)"', line)
        if match: level = match[1]
        for path in re.findall(r'::/([^"$]+\.HC)', line): levels['C:/' + path] = level
        for path in re.findall(r'\$MA[^$]*,"::/([^"]+)",LM=', line): directory_levels['C:/' + path] = level
    native_file = os.path.join(shared, 'native-translation/manifest.json')
    native = {n['path']: n for n in json.load(open(native_file))['sources']} if os.path.exists(native_file) else {}
    for p in progs:
        n = native.get(p['path'], {})
        p['sourceSHA256'] = hashlib.sha256(open(os.path.join(shared, 'bundled-fs', p['path'][3:]), 'rb').read()).hexdigest()
        p['launch'] = {'type': 'source-only' if p.get('discoveryRole') and p['status'] == 'unsupported' else 'include', 'path': p['path']}
        if p['id']=='original.jukebox':
            p['launch'].update(entrypoint='JukeBox', arguments=['C:/Apps/Psalmody/Examples', 0])
            p['controls']=['mouse','arrows','keyboard'];p['capabilities']=['console','graphics','sound','files']
        if p['id']=='app.grmodels':
            # PersonalMenu: #include "::/Apps/GrModels/Run";View;
            # The existing post-source launch interface works in both engines.
            p['launch'].update(entrypoint='View',arguments=[])
        if p['id']=='demo.wallpaperctrl':
            p['launch'].update(context='adam-resident',entrypoint='MobileResident',arguments=[])
        if p['id']=='app.timeclock':
            p['launch'].update(entrypoint='MobileCommandMenu',arguments=['PunchIn\0PunchOut\0TimeRep\0\0'])
            p['controls']=['menu','keyboard'];p['capabilities']=['console','files']
        if p['id'] in FULL_KEYBOARD:
            p['controls'].append('full_keyboard')
        row = next((r for r in distribution['files'] if r['path'] == p['path']), {})
        p['dependencies'] = sorted(set(path for path in n.get('closure', {}) if path != p['path']) | set(row.get('dependencies', [])))
        p['missingDependencies'] = [d for d in p['dependencies'] if not (Path(shared) / 'bundled-fs' / d[3:]).is_file()]
        translated = n.get('status') == 'translated' and not n.get('requires_terry')
        p['executionModes'] = {'holyC': p['status'], 'nativeSwift': 'translated' if translated else 'unavailable', 'nativeKotlin': 'translated' if translated else 'unavailable'}
        modules=[v.split(':',1)[0] for v in n.get('variants',[])] or ([n['module']] if n.get('module') else [])
        p['nativeImplementations']={'swift':['PureSwift/Generated/'+m+'.swift' for m in modules],
                                    'kotlin':['purekotlin/gen/'+m+'.kt' for m in modules]}
        original = next((e for e in menu if e['programId'] == p['id']), None)
        p['originalMenu'] = {k: original[k] for k in ['title','category','order','row','column','asset','sprite']} if original else None
        directory = next((d for d in sorted(directory_levels, key=len, reverse=True) if p['path'].startswith(d + '/')), None)
        p['demoIndexCategory'] = levels.get(p['path']) or directory_levels.get(directory)
        p['demoIndexReference'] = 'file' if p['path'] in levels else 'directory' if directory else None
        p['verification'] = 'See docs/games-preservation/VERIFICATION.md; registration alone is not verification'
        if p.get('discoveryRole'):
            p['verification'] = 'Source discovery verified; execution unverified. See docs/distribution-audit.'
        p['verification'] = compat.get(p['id'],{}).get('verification',p['verification'])
        p['groups'] = [g['id'] for g in distribution['groups'] if p['id'] in g['programIds']]
    original = Path(__file__).resolve().parents[2] / 'reference/templeos-iso'
    iso_manifest = json.loads((original / 'MANIFEST.json').read_text())
    names = {p.lower(): p for p in iso_manifest['files']}
    from discover import resolve
    menus = menu_inventory({p: (original / p).read_bytes() for p in iso_manifest['files']}, progs,
                           lambda p, base: resolve(p, base, names), menu)
    docs = original.parents[1] / 'docs/distribution-audit'
    (docs / 'menu-inventory.json').write_text(json.dumps(menus, indent=1) + '\n')
    # Existing content-moderation edits also apply to generated UI metadata.
    # The engineering inventory above remains a record of the original source.
    from moderation import moderate
    runtime_menus = menu_inventory({p:moderate(p,(original / p).read_bytes())[0] for p in iso_manifest['files']},progs,
                                  lambda p,base:resolve(p,base,names),menu)
    Path(shared, 'runtime/original-menus.json').write_text(json.dumps({'version': 1, 'menus': runtime_menus['menus'], 'symbols':runtime_menus['symbols']}, indent=1) + '\n')
    groups = distribution['groups']
    groups.append(dict(id='menus', title='Original menus', parent='programs', source='TempleOS V5.03 source definitions', programIds=[], menuIds=[], presentation='links'))
    for kind, label in [('document','Document launchers'),('pulldown','Pull-down menus'),('popup','Popups and choosers'),('document-menu','Document menus'),('generated-document','Generated document menus')]:
        groups.append(dict(id='menus.' + kind, title=label, parent='menus', source=kind, programIds=[], menuIds=[m['id'] for m in menus['menus'] if m['menuType'] == kind], presentation='links'))
    groups.append(dict(id='games', title='Games', parent='', source='C:/PersonalMenu.DD', programIds=[e['programId'] for e in menu], presentation='icons'))
    for p in progs:p['groups']=[g['id'] for g in groups if p['id'] in g['programIds']]
    out = os.path.join(shared, 'program-manifests', 'catalog.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({'version': 2, 'programs': progs, 'groups': distribution['groups']}, open(out, 'w'), indent=1)
    doc = Path(__file__).resolve().parents[2] / 'docs/distribution-audit/distribution.json'
    doc.write_text(json.dumps(distribution, indent=1) + '\n')
    profiles=[]
    for p in progs:
        launch=p['launch']
        if 'entrypoint' not in launch:continue
        args=launch.get('arguments',[])
        assert len(args)<=8
        fields=[p['path'],launch.get('context','user'),launch['entrypoint']]
        fields += ['s'+a.encode('latin1').hex() if isinstance(a,str) else 'i'+str(a) for a in args]
        profiles.append('\t'.join(fields))
    open(os.path.join(shared,'runtime/program-launch.tsv'),'w').write('\n'.join(profiles)+'\n')
    print(f'{out}: {len(progs)} programs')


if __name__ == '__main__':
    main(sys.argv[1])
