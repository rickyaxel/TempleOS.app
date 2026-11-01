#!/usr/bin/env python3
"""Generate reviewable inventories from the reconciled ISO and runtime manifests.

This reports static evidence and separately observed tests. It never infers runtime
compatibility from compilation, a catalog entry, or a menu route lookup.
"""
import collections
import json
import re
from pathlib import Path
from menus import LEX

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/distribution-audit'


def read(path):
    return json.loads((ROOT / path).read_text())


def write(name, text):
    (OUT / name).write_text(text.rstrip() + '\n')


def dump(name, value):
    write(name, json.dumps(value, indent=2, ensure_ascii=False))


def cell(value):
    return str('—' if value is None or value == '' else value).replace('|', '\\|').replace('\n', ' ')


def table(headers, rows):
    return '\n'.join(['| ' + ' | '.join(headers) + ' |', '| ' + ' | '.join(['---'] * len(headers)) + ' |'] +
                     ['| ' + ' | '.join(cell(x) for x in row) + ' |' for row in rows])


def main():
    dist = read('docs/distribution-audit/distribution.json')
    menus = read('docs/distribution-audit/menu-inventory.json')
    catalog = read('shared/program-manifests/catalog.json')
    baseline = read('docs/distribution-audit/baseline-catalog.json')
    native = read('shared/native-translation/manifest.json')
    icons = read('docs/games-preservation/icon-manifest.json')
    programs = catalog['programs']; groups = catalog['groups']; summary = dist['summary']
    previous = {p['id'] for p in baseline['programs']}
    files = {r['path']: r for r in dist['files']}
    candidate_paths={r['path'] for r in dist['files'] if r.get('relevantPresentation')}
    catalog_paths={p['path'] for p in programs}
    inspection_references=sorted(candidate_paths-catalog_paths)
    observed = {}
    archive=OUT / 'evidence/program-support'
    def evidence_path(path):
        saved=archive / path.name
        return str((saved if saved.is_file() else path).relative_to(ROOT))
    for evidence in sorted(archive.glob('*.json')) + sorted((ROOT / 'temple_os_swift/TempleCore/.build/distribution-support').glob('*.json')):
        result = json.loads(evidence.read_text())
        observed.setdefault(result['path'], {})['Swift ' + result['engine']] = evidence_path(evidence)
    for evidence in sorted(archive.glob('*.txt')) + sorted((ROOT / 'temple_os_kotlin/purekotlin/build/distribution-support').glob('*.txt')):
        header = dict(line.split('=',1) for line in evidence.read_text().splitlines()[:3] if '=' in line)
        if header.get('path') and header.get('engine'):
            observed.setdefault(header['path'], {})['Kotlin ' + header['engine']] = evidence_path(evidence)
    inventory = []
    for p in programs:
        source = files.get(p['path'], {})
        srcpath=ROOT / ('reference/templeos-iso/' if source else 'shared/bundled-fs/') / p['path'][3:]
        text=srcpath.read_bytes().split(b'\0')[0].decode('latin1') if srcpath.is_file() else ''
        tokens=[m[0] for m in LEX.finditer(text) if not m[0].isspace() and not m[0].startswith(('//','/*'))]
        calls=sorted({tokens[i] for i in range(len(tokens)-1) if re.fullmatch(r'[A-Za-z_]\w*',tokens[i]) and tokens[i+1]=='(' and tokens[i] not in {'if','for','while','switch','catch','sizeof','offset'}})
        words=set(tokens)
        inventory.append(dict(
            stableId=p['id'], originalName=(p.get('originalMenu') or {}).get('title',p.get('historicalTitle', p['title'])), title=p['title'],
            sourcePath=p['path'], sourceVersion=p['source'], sourceSHA256=p['sourceSHA256'],
            originalSourceSHA256=source.get('sha256'), bundledSourceSHA256=source.get('bundleSHA256',p['sourceSHA256']),
            historicalMenu=p.get('originalMenu'), demoIndex=p.get('demoIndexCategory'),
            mobileGroups=p.get('groups', []), entryPoint=p['launch'],
            sourceRole=source.get('role', 'mobile-example'), entryEvidence=source.get('entryEvidence', []),
            dependencies=p['dependencies'], missingDependencies=p['missingDependencies'],
            sourceFiles=[p['path']]+p['dependencies'],
            staticCallNameEvidence=calls,
            inputAPIEvidence=[s for s in calls if s in {'GetChar','GetKey','ScanChar','ScanKey','GetMsg','ScanMsg','MsSet','GetStr','GetI64','GetF64'}],
            soundAPIEvidence=[s for s in calls if s in {'Snd','Play','Beep','Noise','Sweep','SndTaskEndCB'}],
            globalReferenceEvidence=sorted(words & {'Fs','Gs','ms','gr','kbd','sys_focus_task','adam_task','text','doldoc','winmgr'}),
            persistenceCallEvidence=[s for s in calls if s in {'FileWrite','FilePrint','RegWrite','RegDft','DirMk','Del','Move','Copy','Ed'}],
            dependencyCoverage='Static include/translated closure; dynamic expressions retained in original file record. Lexical call names also include declarations and are not a complete runtime API proof.',
            sourceReferences=source.get('referencedBy', []), animationEvidence=source.get('animationEvidence', {}),
            swiftCatalog='present', kotlinCatalog='present', newlyPresented=p['id'] not in previous,
            executionCompatibility=p['executionModes'], nativeImplementations=p['nativeImplementations'],
            controls=p['controls'], soundRequired='sound' in p['capabilities'],
            limitation=p['note'], omissionCause=source.get('omissionCause'),
            resolution='Shared source-backed presentation and explicit source-only action' if p['status'] == 'unsupported'
                else 'Shared registration; use existing native/HolyC launch interfaces',
            verification=p['verification'], observedEngineEvidence=observed.get(p['path'], {}),
            verificationScope='See CROSS_PLATFORM_VERIFICATION.md; declaration/translation is not an end-to-end pass'))
    dump('program-inventory.json', dict(version=1, programs=inventory, coverage=summary,
        exclusions='See original file reconciliation; source-only and excluded host/system operations are not execution claims.'))

    counts = collections.Counter(m['menuType'] for m in menus['menus'])
    personal = next(m for m in menus['menus'] if m['source'] == 'C:/PersonalMenu.DD')
    write('COMPLETE_PROGRAM_INVENTORY.md', f'''# Complete program and source inventory

The audit boundary is the bundled **{summary['sourceVersion']}** ISO, SHA-256
`{summary['isoSHA256']}`. Every manifest file is hashed and classified; the archive and
expanded authoritative sources are unmodified. Host metadata such as `.DS_Store`
is excluded. [Full file reconciliation](distribution.json), [program records](program-inventory.json),
[runtime catalog](../../shared/program-manifests/catalog.json).

## Reconciliation

{table(['Measure', 'Observed count'], [
    ('Non-root directories', summary['directoriesScanned']), ('Original files', summary['filesExamined']),
    ('Source files (.HC/.HH/.IN/.CPP/.PRJ)', summary['sourceFilesExamined']),
    ('HolyC files', summary['holyCFilesExamined']),
    ('Documents containing controls/macros (narrow scan)', summary['menuDocuments']),
    ('Source/document files containing menu primitives (narrow scan)', summary['menuDefinitions']),
    ('PersonalMenu icon groups', summary['personalMenuGroups']), ('Demo Index groups', summary['demoIndexGroups']),
    ('Explicit #help_index names (separate taxonomy)', summary['helpIndexGroups']),
    ('Candidate program/source presentations', summary['candidates']),
    ('Candidate paths represented by catalog / excluded host-tool references', str(len(candidate_paths & catalog_paths))+' / '+str(len(inspection_references))),
    ('Self-starting .HC units (lexical evidence, not compatibility)', summary['standalonePrograms']),
    ('Application entry units', summary['roles']['application']),
    ('Standalone demonstration units', summary['roles']['standalone-demo']),
    ('Original default PersonalMenu actions/links', len(personal['entries'])),
    ('Original icon-bearing entries / extracted icons', '28 / 28'),
    ('Prior catalog entries', len(previous)), ('New presentations in each client', len(programs)-len(previous)),
    ('Final catalog entries', len(programs)),
    ('Original / mobile-authored entries', str(sum(p['author']=='Terry A. Davis' for p in programs))+' / '+str(sum(p['author']!='Terry A. Davis' for p in programs))),
    ('Runnable or partial declarations / source-only', str(sum(p['status']!='unsupported' for p in programs))+' / '+str(sum(p['status']=='unsupported' for p in programs))),
    ('Newly verified runnable registrations', 7), ('New hand-written native games', 0),
])}

The 190 self-starting HolyC units comprise 175 demo entry units, 12 application
entry units and three songs. Noninteractive examples are included in that count.
The scripted Tour is one presentation with twelve supporting segments; helpers,
loaders, asset generators and private account initialization are not independent
program tiles. JukeBox is a compound launcher, distinct from its song examples.
The 239 candidates include command libraries, examples and installation references;
they are not 239 certified playable applications. The 222 runtime groups are mobile
routes and historical cross references, not 222 original top-level menus.
Of the 239 candidate paths, {len(candidate_paths & catalog_paths)} have catalog
records. The three original Linux host tools remain explicit unavailable
references under Programs → Commands and utilities → Linux distribution tools:
{', '.join('`'+p+'`' for p in inspection_references)}.
They are preserved in the authoritative archive, not executed or silently counted
as mobile programs. JukeBox adds a reviewed compound Load.HC + JukeBox launcher
outside the standalone-source heuristic, accounting for 237 original registrations.

## Every original file role

{table(['Role', 'Files'], sorted(summary['roles'].items()))}

The role counts sum to all 652 original files. Libraries, dependencies, documents,
data, internal code and host tools remain in the reconciliation even when they do
not warrant launch tiles. Complete directory coverage is listed below.

{table(['Original directory'], [(p,) for p in dist['directories']])}

## Catalog and gap resolution

All additions below were absent from both old client catalogs. Their original source
was already bundled in most cases; exclusion from fixed registration allowlists was
the presentation defect. Runtime compile diagnostics and unverified execution are
kept separately in each source row. Translation alone never promotes a program.
Seven bounded workflows were verified in all four engine/platform configurations:
DateTime, RadixSort, MsgLoop, KeyBitMap, PullDownMenu, MenuBttn and MenuSprite.
All other new presentations retain a source-only state.

WaterFowl retains stable ID `sound.waterfowl`, source `C:/Demo/Snd/WaterFowl.HC`,
and Games: Intermediate membership. It is supplementary gallery access, not an
invented PersonalMenu icon. Existing 107 registrations retain their IDs.
Original icon captions and source/catalog titles are recorded separately: for
example Models → GrModels, Golf → BomberGolf and Lines → BattleLines all resolve
to one underlying program. The gallery keeps the original caption artwork;
these aliases do not create duplicate implementations.

{table(['ID', 'Title', 'Original source', 'Status', 'New', 'Limitation / verification'], [
    (p['id'],p['title'],p['path'],p['status'],'yes' if p['id'] not in previous else '',p['note'] or p['verification']) for p in programs])}

`program-inventory.json` supplies entry points, dependencies, hashes, animation
source evidence, both native implementation references, both catalog statuses,
historical indexes, controls and verification scope. `distribution.json` additionally
retains compiler diagnostics, dynamic file expressions and every noncatalog file.
''')

    menu_rows = []
    for m in menus['menus']:
        menu_rows.append((m['id'],m['title'],m['source']+':'+str(m['sourceLine']),m['menuType'],
            len(m['entries']),m['scope'],'template' if m['dynamic'] else 'constant',m['mobileRoute']))
    details = []
    for m in menus['menus']:
        details.append('## '+m['id']+' — '+m['title']+'\n\n'+
            f"Source: `{m['source']}:{m['sourceLine']}`; type: {m['menuType']}; invocation: `{m['invokedFrom']}`; "
            f"parent: {m['historicalParent']}; layout: {m['layout']}. "
            f"Native mapping: {m['nativePresentation']}. Evidence: {m['verification']}.\n\n"+
            table(['Order','Group','Entry','Semantics','Target','Availability'],[(e['originalOrder'],e['group'],e['label'],e['actionKind'],e.get('programId') or e.get('target') or e.get('symbol'),e['availability']) for e in m['entries']])+'\n')
    write('COMPLETE_TEMPLEOS_MENU_INVENTORY.md', f'''# Original menu definitions and activation inventory

{len(menus['menus'])} source records: {', '.join(str(n)+' '+k for k,n in sorted(counts.items()))}.
There are {len(menus['callSites'])} API call sites, {len(menus['infrastructure'])} infrastructure
definitions and {len(menus['edges'])} resolved/typed entry edges in the static graph.
These are **definitions, templates and activation sites**, not a count of unique
visible runtime menus. Document records include ordinary navigation links.

[Machine-readable full entries](menu-inventory.json) retain original expressions,
event arguments, source locations, shortcuts, left/right attributes, required
context, icon references, owner program IDs and dynamic coverage notes.
The native menu explorer exposes every record without executing reference commands
outside its original context. Program-owned event menus remain in their program.

Dynamic document fragments are grouped by lexical owning function. That records
known literal output templates; it does not enumerate arbitrary runtime strings,
pointer values, file listings or conditional state combinations. A record with no
constant entries remains inspectable at its original source. Calls through
function pointers and computed source strings require runtime investigation beyond
this static pass; they are not claimed exhaustively reproduced.

{table(['ID','Title','Source:line','Type','Entries','Scope','Evidence','Route'], menu_rows)}

{chr(10).join(details)}
''')

    nodes = [dict(id='menu:'+m['id'],type='historicalMenu',source=m['source'],dynamic=m['dynamic']) for m in menus['menus']]
    nodes += [dict(id='group:'+g['id'],type='mobileGroup',title=g['title'],source=g['source']) for g in groups]
    nodes += [dict(id='program:'+p['id'],type='program',source=p['path'],status=p['status']) for p in programs]
    edges = [dict(source='menu:'+e['fromMenu'],target=('program:' if e['kind']=='launchProgram' else '')+e['target'],kind=e['kind'],historical=True,entry=e['entry'],context=e['context'],availability=e['availability']) for e in menus['edges']]
    # Preserve indirect popup/creator calls as well as document-entry targets.
    # This is a static activation graph; an include closure is not proof that a
    # conditional helper actually executes in every run.
    contexts={};apis={}
    for call in menus['callSites']:
        cid='context:'+call['source']+'#'+call['context'];aid='api:'+call['api']
        contexts[cid]=dict(id=cid,type='sourceFunctionContext',source=call['source'],function=call['context'])
        apis[aid]=dict(id=aid,type='originalAPI',symbol=call['api'],sources=menus['symbols'].get(call['api'],[]))
        kind='openPopup' if call['api'].startswith('PopUp') else 'spawnTask' if call['api']=='Spawn' else 'invokeMenu' if call['api'].startswith('Menu') or call['api']=='DocMenu' else 'callOriginalAPI'
        edges.append(dict(source=cid,target=aid,kind=kind,historical=True,sourceLine=call['sourceLine'],arguments=call['arguments'],availability='original-context',evidence='static call site; conditions and computed arguments require runtime state'))
        for m in menus['menus']:
            if m['source']==call['source'] and m['sourceLine']==call['sourceLine'] and m['menuType']!='generated-document':
                edges.append(dict(source=cid,target='menu:'+m['id'],kind='activatesDefinition',historical=True))
    nodes += list(contexts.values())+list(apis.values())
    for m in menus['menus']:
        if 'api:'+m['invokedFrom'] in apis:
            edges.append(dict(source='api:'+m['invokedFrom'],target='menu:'+m['id'],kind='definesMenuTemplate',historical=True))
        if m['menuType']!='generated-document':
            for template in menus['menus']:
                if template['menuType']=='generated-document' and template['source']==m['source'] and template['invokedFrom']==m['invokedFrom']:
                    edges.append(dict(source='menu:'+m['id'],target='menu:'+template['id'],kind='generatedContentTemplate',historical=True))
    for context in contexts.values():
        for p in programs:
            if context['source']==p['path'] or context['source'] in p['dependencies']:
                edges.append(dict(source='program:'+p['id'],target=context['id'],kind='declaresMenuContext',historical=True,evidence='static source/dependency relationship; not unconditional execution'))
    for g in groups:
        if g['parent']:edges.append(dict(source='group:'+g['parent'],target='group:'+g['id'],kind='navigate',historical=False))
        for pid in g['programIds']:edges.append(dict(source='group:'+g['id'],target='program:'+pid,kind='programDetail',historical=False))
        for mid in g.get('menuIds',[]):edges.append(dict(source='group:'+g['id'],target='menu:'+mid,kind='inspectOriginalMenu',historical=False))
        if g.get('directory'):edges.append(dict(source='group:'+g['id'],target=g['directory'],kind='openDirectory',historical=False))
        if g.get('document'):edges.append(dict(source='group:'+g['id'],target=g['document'],kind='openDocument',historical=False))
    for p in programs:
        edges.append(dict(source='program:'+p['id'],target=p['path'],kind='openSource',historical=False))
        if p['status']!='unsupported':edges.append(dict(source='program:'+p['id'],target=p['path'],kind='launchSelectedEngine',historical=False))
        edges.append(dict(source='program:'+p['id'],target='originating window ID',kind='returnToOrigin',historical=False))
    dump('navigation-graph.json',dict(version=1,nodes=nodes,edges=edges,coverage=menus['coverage'],
        returnSemantics='Originating window IDs, saved group route and scroll; not a fixed return to intro.'))
    write('MENU_NAVIGATION_GRAPH.md','''# Menu navigation graph

[Full typed graph](navigation-graph.json) separates source-derived edges (`historical=true`)
from the deliberate mobile hierarchy. File/document/symbol destinations are external
graph nodes by canonical C: path; context event destinations are owning tasks.
An unresolved source template is retained in the menu inventory, rather than
inventing a successful graph edge.

The graph also retains all 543 discovered menu API call sites, their enclosing
functions, definition/template bindings and static program dependency references.
These edges make indirect popup/menu creation inspectable; a static dependency
edge does not assert that the function runs unconditionally. The 2,248 typed
entry edges and call-site edges are separate counts. Runtime-generated strings,
function-pointer choices and filesystem/task-dependent contents remain bounded
coverage, with original expressions recorded instead of invented targets.

```mermaid
flowchart TD
  Intro[Exact intro] --> MENU
  MENU --> Games[Games: native icon gallery]
  Games --> Historical[Fun / Unfun / Code Scraps / Nongames]
  Games --> Supplementary[More programs: existing supported catalog]
  MENU --> Apps[Applications]
  MENU --> Demos[Original Demo Index: five ordered groups]
  MENU --> Programs[Programs hub]
  Programs --> Folders[Demo directories / Original filesystem]
  Programs --> Tools[Commands / Tour / Linux source references]
  Programs --> Docs[Documentation / help indexes]
  Programs --> Menus[Original menu references by presentation type]
  Historical --> Runtime[Selected HolyC or native engine]
  Apps --> Detail[Program detail / source]
  Demos --> Detail
  Detail --> Runtime
  Runtime --> Context[Original program menu / popup]
  Context --> Runtime
  Runtime --> Origin[Exit/close: restore originating window]
```

The four Games categories and five Demo Index groups are historical. The extra
Games page, Programs hub and grouping of menu-reference records are mobile
adaptations. Context commands are not promoted to global launchers.

Pull-down events go to the current focused task. Its nearest ancestor with a menu
supplies the menu contents, matching Adam/Menu.HC. MenuPop restores the previous
task menu. Native editor and file-manager adapters accept only explicitly mapped
commands; other original entries remain disabled. Original disk operations have
no host route.

Back dismisses a popup/menu first, then follows document/group history, then
restores the originating window. Saved window-ID mappings preserve return paths
after session restoration. Group scroll and keyboard selection are retained;
selecting Programs from the root MENU deliberately reopens its hub. Cyclic
cross references collapse history instead of growing an unbounded stack.
''')

    write('PROGRAM_GROUP_NAVIGATION_SPECIFICATION.md','''# Native program navigation specification

MENU retains terminal, editor, files, Games, examples, documentation, God Words,
Paint, settings, language and About. Applications, Programs and the source-defined
Demo Index are integrated into that same menu. No second navigation framework is
introduced.

Games uses the existing App/Surface/window host and extracted sprites. Programs
uses document-style text, ordered links, source paths, scroll controls and Back.
Program details show a Run action only for runnable/partial registrations and
always show source inspection. The engine is the existing session setting, not a
new per-view substitute. Source-only entries do not create fake execution windows.

Original menu references are source-inspection routes. Their known document,
directory and program actions use typed destination adapters. Event commands can
only run from the associated live program, editor or selected-file context.
Unknown macros remain inspection-only in this explorer. Existing user-authored
sandbox terminal behavior is retained separately.

The generated registry below is consumed by both clients. Paths are resolved through
the same original C: filesystem, case-insensitive lookup and expanded .Z aliases;
Home/PersonalMenu and Welcome defaults fall back to their original source locations.
Package loaders share sources/dependencies; no additional filesystem copies are made.

'''+table(['Group ID','Title','Parent','Historical source','Programs','Menu references'],[(g['id'],g['title'],g['parent'],g['source'],len(g['programIds']),len(g.get('menuIds',[]))) for g in groups]))

    write('NEW_PRESENTATIONS.md','# New program presentations\n\n'+
        'Every row was missing from both baseline catalogs. Execution remains source-only unless explicitly shown otherwise.\n\n'+
        table(['Stable ID','Title','Original path','Status'],[(p['id'],p['title'],p['path'],p['status']) for p in programs if p['id'] not in previous]))
    print(json.dumps(dict(programs=len(programs),additions=len(programs)-len(previous),groups=len(groups),menus=len(menus['menus']),menuTypes=counts,edges=len(menus['edges']),fileRoles=summary['roles']),indent=2))


if __name__ == '__main__':
    main()
