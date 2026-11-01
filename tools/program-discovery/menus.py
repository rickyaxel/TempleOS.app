#!/usr/bin/env python3
"""Source-backed menu definitions, call sites and semantic edges.

Constant pull-down strings are parsed; generated documents retain their template
fragments and runtime context. Static discovery never claims to enumerate all
outputs of arbitrary HolyC. No expression is executed by this tool or its UI.
"""
import hashlib
import re
from pathlib import Path

APIS = {'MenuNew', 'MenuFile', 'MenuPush', 'MenuFilePush', 'MenuPop', 'MenuEntryFind',
        'DocMenu', 'PopUpMenu', 'DocRead', 'PopUpPickLst', 'PopUpPickDefineSub',
        'PopUpPickDir', 'PopUpPickFile', 'PopUpFileName', 'PopUpForm', 'DocForm',
        'PopUp', 'PopUpPrint', 'PopUpViewDoc', 'PopUpViewPrint', 'FileMgr',
        'DocEntryRun', 'InFile', 'Spawn', 'TaskExe', 'XTalk'}
LEX = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|\s+|.', re.S)
QSTR = re.compile(r'"((?:\\.|[^"\\])*)"', re.S)


def uid(path, context, kind, ordinal=0):
    return kind + '.' + hashlib.sha256((path + '\n' + context + '\n' + str(ordinal)).encode()).hexdigest()[:16]


def unquote(s):
    return re.sub(r'\\(x[0-9A-Fa-f]{2}|[nrt0"\'\\])', lambda m: chr(int(m[1][1:], 16)) if m[1].startswith('x') else
                  {'n': '\n', 'r': '\r', 't': '\t', '0': '\0', '"': '"', "'": "'", '\\': '\\'}[m[1]], s)


def split_args(s):
    result = []; start = 0; depth = 0
    for m in LEX.finditer(s):
        t = m[0]
        if t in ('(', '[', '{'): depth += 1
        if t in (')', ']', '}'): depth -= 1
        if t == ',' and depth == 0:
            result.append(s[start:m.start()].strip()); start = m.end()
    result.append(s[start:].strip())
    return result


def pulldown(src):
    """Parse the two-level MenuNew language without evaluating HolyC events."""
    entries = []; stack = []; pos = 0
    pattern = re.compile(r'([A-Za-z_]\w*)\s*(\{|\()|\}')
    while match := pattern.search(src, pos):
        if match[0] == '}':
            if stack: stack.pop()
            pos = match.end(); continue
        name = match[1]
        if match[2] == '{':
            stack.append(name); pos = match.end(); continue
        end = src.find(');', match.end())
        if end < 0: break
        args = split_args(src[match.end():end])
        args += [''] * (3 - len(args))
        entries.append(dict(id='entry.' + str(len(entries)), label=name, originalOrder=len(entries),
                            group='/'.join(stack), originalAction=name + '(' + src[match.end():end] + ');',
                            actionKind='sendEvent', msgCode=args[0] or 'MSG_KEY_DOWN_UP',
                            arg1=args[1] or '0', arg2=args[2] or '0',
                            requiredContext='active task owning this menu', availability='runtime-context',
                            target='', programId='', iconAsset='', keyboardShortcut=args[2] or args[1],
                            popup=False, spawnsTask=False, globalNavigation=False))
        pos = end + 2
    return entries


def semantic(tag, body, label, path, resolve, bypath):
    attrs = {m[1]: unquote(m[2]) if m[2] is not None else m[3]
             for m in re.finditer(r'\b([A-Z][A-Z0-9_]*)=(?:"((?:\\.|[^"\\])*)"|([^,$]+))', body)}
    macro = attrs.get('LM', '')
    target = ''; pid = ''; kind = 'inspect'; available = 'source-only'
    reason = ''; symbol = ''; popup = '+PU' in tag
    if tag.startswith('TR'):
        kind = 'toggleTree'; available = 'document-context'
    elif tag.startswith('LS'):
        kind = 'openChooser'; available = 'runtime-context'
    elif macro:
        inc = re.search(r'#include\s+"([^"]+)"', macro)
        cd = re.search(r'\bCd\("([^"]+)"\)', macro)
        if inc:
            target = resolve(inc[1], path) or ''
            p = bypath.get(target)
            if p:
                pid = p['id']; kind = 'launchProgram'
                available = 'source-only' if p.get('status') == 'unsupported' else 'supported'
                if pid == 'original.jukebox' and not re.search(r'JukeBox\("(?:::|C:)/Apps/Psalmody/Examples"\)',macro):
                    available='source-only'
                    reason='This account-specific launcher has different arguments/data from the default JukeBox registration.'
            else:
                kind = 'includeSource'; available = 'source-only' if target else 'dynamic'
                reason = 'This include/macro has no reviewed standalone mobile launch registration; inspect its original source.'
        elif cd:
            target = cd[1].replace('::/', 'C:/').replace('~/', 'C:/Home/')
            if target.startswith('/'):
                target = 'C:' + target
            kind = 'openDirectory'; available = 'supported' if target.startswith('C:/') else 'context-only'
            if 'InFile' in macro:
                kind = 'runInputScript'; available = 'source-only'
                reason = 'Scripted interactive tour requires the original desktop command/input context.'
        elif macro.strip() in ('Cd;Dir;\n', 'Cd;Dir;'):
            kind = 'openDirectory'; target = 'C:/Home'; available = 'supported'
        else:
            kind = 'performCommand'; available = 'context-only'
            reason = 'Original system or contextual command; no host command is executed.'
    elif tag.startswith('LK'):
        positional = [unquote(m[1]) for m in QSTR.finditer(body)]
        link = attrs.get('A', positional[1] if len(positional)>1 else label)
        if link.startswith(('MN:', 'HI:', 'DN:', 'BF:', 'AD:')):
            symbol = link
            kind = 'openHelpIndex' if link.startswith('HI:') else 'openSymbol'
            available = 'source-only'
        else:
            link = re.sub(r'^(FI|FA|FF|FL|PI|PF|PL):', '', link)
            target = resolve(link.split(',')[0], path) or ''
            kind = 'openDocument' if target.endswith(('.DD', '.TXT')) else 'openSource'
            available = 'supported' if target else 'unresolved'
    elif 'LE' in attrs or 'RE' in attrs:
        kind = 'returnValue'; available = 'runtime-context'
    elif tag.startswith('SP'):
        kind = 'artwork'; available = 'document-context'
    return dict(id='', label=label, originalOrder=0, group='', originalAction=macro or body,
                actionKind=kind, target=target, programId=pid, iconAsset='',
                sprite=attrs.get('BI'), symbol=symbol, keyboardShortcut='', requiredContext='document or owning task',
                availability=available, reason=reason, popup=popup, spawnsTask=popup,
                globalNavigation=kind in {'launchProgram', 'openDocument', 'openDirectory'},
                originalFlags=tag,activationType='Space/left pointer; Enter/right pointer',
                leftAction={k:attrs[k] for k in ['LM','LE','LC'] if k in attrs},
                rightAction={k:attrs[k] for k in ['RM','RE','RC'] if k in attrs})


def markup(src, path, resolve, bypath):
    result = []
    # Quoted labels may contain dollars and escaped quotes. Attribute strings are
    # scanned atomically so macro source cannot end a DolDoc tag prematurely.
    pattern = re.compile(r'\$(SP[^,$]*|MA[^,$]*|LK[^,$]*|MU[^,$]*|BT[^,$]*|TR[^,$]*|LS[^,$]*)'
                         r'((?:"(?:\\.|[^"\\])*"|[^$"\n])*)\$', re.S)
    group = ''
    for m in pattern.finditer(src):
        label_match = re.match(r',"((?:\\.|[^"\\])*)"', m[2])
        label = unquote(label_match[1]) if label_match else ''
        e = semantic(m[1], m[2], label, path, resolve, bypath)
        if m[1].startswith('TR'): group = label
        e.update(id='entry.' + str(len(result)), originalOrder=len(result), group=group,
                 sourceLine=src[:m.start()].count('\n') + 1)
        result.append(e)
    return result


def inventory(raw, programs, resolver, menu_assets):
    bypath = {p['path']: p for p in programs}
    records = []; callsites = []; infrastructure = []; edges = []; symbols = {}
    for rel, data in sorted(raw.items()):
        path = 'C:/' + rel
        src = data.split(b'\0')[0].decode('latin1')
        if not rel.endswith(('.HC', '.HH', '.IN', '.DD', '.PRJ')): continue
        if rel.endswith(('.HC','.HH')):
            declarations = re.findall(r'(?m)^\s*(?:public\s+)?(?:[IU][0-9]+|F64|Bool|U0|C\w+)\s+\**\s*(\w+)\s*(?:\([^;{}]*\)\s*\{|[=;\[])',src)
            declarations += re.findall(r'(?m)^\s*#define\s+(\w+)',src)
            declarations += re.findall(r'(?m)^\s*(?:public\s+)?(?:class|union)\s+(\w+)',src)
            for symbol in declarations:
                symbols.setdefault(symbol,[])
                if path not in symbols[symbol]:symbols[symbol].append(path)
        if rel in {'Doc/EdPullDown.DD', 'Doc/FileMgrPullDown.DD'}:
            entries = pulldown(src)
            context = 'editor' if 'EdPullDown' in rel else 'file-manager'
            for e in entries:
                e['requiredContext'] = context
            records.append(dict(id=uid(path, '', 'pulldown'), title=Path(rel).stem, source=path, sourceLine=1,
                                menuType='pulldown', invokedFrom='MenuFilePush', historicalParent=context,
                                entries=entries, dynamic=False, layout='two-level blue/yellow event menu',
                                nativePresentation='contextual native menu overlay', verification='source parsed; see verification report'))
            continue
        if rel.endswith('.DD'):
            entries = markup(src, rel, resolver, bypath)
            if entries:
                records.append(dict(id=uid(path, '', 'document'), title=Path(rel).stem, source=path, sourceLine=1,
                                    menuType='document', invokedFrom='DocRead / editor document links',
                                    historicalParent='document', entries=entries, dynamic=False,
                                    layout='DolDoc links, trees and embedded sprites', nativePresentation='document view / original icon gallery',
                                    verification='static tags parsed; runtime reference coverage is separate'))
            continue
        tokens = list(LEX.finditer(src))
        depth = 0; context = '<global>'; header = ''; strings = {}; ordinals = {}
        for i, tok in enumerate(tokens):
            value = tok[0]
            if value.startswith(('/*', '//')): continue
            if value == '{':
                if depth == 0:
                    match = re.search(r'(\w+)\s*\([^;{}]*\)\s*$', header)
                    context = match[1] if match else '<global>'
                    header = ''
                depth += 1
            elif value == '}':
                depth = max(0, depth - 1)
                if depth == 0: context = '<global>'; header = ''
            elif value == ';' and depth == 0:
                header = ''
            elif depth == 0:
                header += value
            if value.startswith('"'):
                strings.setdefault(context, []).append((tok.start(), unquote(value[1:-1])))
            if value not in APIS and not re.fullmatch(r'PopUp\w+|Menu[A-Z]\w+',value): continue
            j = i + 1
            while j < len(tokens) and tokens[j][0].isspace(): j += 1
            if j == len(tokens):continue
            if tokens[j][0] == ';':
                callsites.append(dict(api=value,source=path,sourceLine=src[:tok.start()].count('\n')+1,context=context,arguments=[]))
                continue
            if tokens[j][0] != '(': continue
            k = j + 1; nesting = 1
            while k < len(tokens) and nesting:
                t = tokens[k][0]
                if t == '(': nesting += 1
                if t == ')': nesting -= 1
                k += 1
            if nesting: continue
            following = k
            while following < len(tokens) and tokens[following][0].isspace(): following += 1
            line = src[:tok.start()].count('\n') + 1
            if following < len(tokens) and tokens[following][0] == '{':
                infrastructure.append(dict(symbol=value, source=path, line=line)); continue
            before = src[src.rfind('\n', 0, tok.start()) + 1:tok.start()].strip()
            if before.startswith(('extern ', 'public ')): continue
            expression = src[tokens[j].end():tokens[k - 1].start()]
            args = split_args(expression)
            call = dict(api=value, source=path, sourceLine=line, context=context, arguments=args)
            callsites.append(call)
            if value not in {'MenuPush', 'MenuNew', 'MenuFile', 'MenuFilePush', 'DocMenu', 'PopUpMenu',
                             'PopUpPickLst', 'PopUpPickDefineSub', 'PopUpPickDir', 'PopUpPickFile', 'PopUpForm'}: continue
            first = args[0] if args else ''
            constant = bool(first) and not QSTR.sub('', first).strip()
            literal = ''.join(unquote(m[1]) for m in QSTR.finditer(first)) if constant else ''
            entries = pulldown(literal) if value in {'MenuPush', 'MenuNew'} and constant else []
            kind = 'pulldown' if value.startswith('Menu') else 'popup' if value.startswith('PopUp') else 'document-menu'
            key = context + ':' + value; ordinal = ordinals.get(key, 0); ordinals[key] = ordinal + 1
            record = dict(id=uid(path, key, kind, ordinal), title=context + ' / ' + value, source=path, sourceLine=line,
                          menuType=kind, invokedFrom=context, historicalParent='owning task', entries=entries,
                          dynamic=not (constant and entries), arguments=args,
                          layout='two-level blue/yellow event menu' if kind == 'pulldown' else 'DolDoc chooser',
                          nativePresentation='program menu overlay' if kind == 'pulldown' else 'sandboxed modal chooser',
                          verification='static call site; generated contents require runtime fixtures')
            if value in {'MenuFile', 'MenuFilePush'} and constant:
                record['templateSource'] = resolver(literal, rel)
            if value == 'PopUpPickLst' and constant:
                record['choices'] = literal.split('\0')
            records.append(record)
        # Every source-generated DolDoc fragment is retained in its owning function.
        for ctx, fragments in strings.items():
            joined = ''.join(s.replace('$$', '$') for _, s in fragments)
            entries = markup(joined, rel, resolver, bypath)
            if not entries: continue
            rec = dict(id=uid(path, ctx, 'generated'), title=ctx, source=path,
                       sourceLine=src[:fragments[0][0]].count('\n') + 1, menuType='generated-document',
                       invokedFrom=ctx, historicalParent='owning task', entries=entries, dynamic=True,
                       layout='conditional DolDoc templates', nativePresentation='original runtime document/chooser',
                       verification='template fragments inventoried; conditions and pointer values evaluated only in sandbox')
            records.append(rec)
    for record in records:
        source = record['source']
        owners = [p['id'] for p in programs if source == p['path'] or source in p.get('dependencies', [])]
        record['ownerProgramIds'] = owners
        # Boot/install include closures reach most OS code. They are provenance,
        # not evidence that a partitioner is an application-specific menu.
        record['scope'] = 'infrastructure' if source in {'C:/Adam/Menu.HC','C:/Adam/DolDoc/DocRun.HC','C:/Adam/DolDoc/DocForm.HC','C:/Adam/DolDoc/DocPopUp.HC','C:/Adam/DolDoc/DocMacro.HC'} else 'document' if record['menuType']=='document' else 'application' if source.startswith(('C:/Apps/','C:/Demo/')) else 'system-context'
        record['mobileRoute'] = 'menu:' + record['id']
        runnable_owner=any(p['id'] in owners and p.get('status')!='unsupported' for p in programs)
        record['availability'] = 'adapter' if record['menuType']=='document' else 'runtime-context' if runnable_owner else 'source-inspection'
        for e in record['entries']:
            e['id'] = record['id'] + '.' + e['id']
            if source == 'C:/PersonalMenu.DD' and e.get('sprite'):
                asset = next((a for a in menu_assets if str(a['sprite']) == e['sprite']), None)
                if asset: e.update(iconAsset=asset['asset'], programId=asset['programId'],group=asset['category'],iconOrder=asset['order'])
            if e.get('target') or e.get('symbol') or e['actionKind'] == 'sendEvent':
                edges.append(dict(fromMenu=record['id'], entry=e['id'], kind=e['actionKind'],
                                  target=e.get('programId') or e.get('target') or e.get('symbol') or record['historicalParent'],
                                  context=e['requiredContext'], availability=e['availability']))
    return dict(version=1, menus=records, callSites=callsites, infrastructure=infrastructure, edges=edges, symbols=symbols,
                coverage='All ISO text/source files scanned. Dynamic outputs are templates/call sites, not exhaustive runtime states.')
