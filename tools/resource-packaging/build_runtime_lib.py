#!/usr/bin/env python3
"""Assemble shared/runtime/GrLib.HC from the original TempleOS graphics library.

Development-only, reproducible. Reads the byte-exact TempleOS V5.03 sources
extracted from the official ISO (tools/asset-extraction/extract_templeos_iso.py)
and writes a single HolyC file that the TempleOS Mobile runtime compiles on top
of its system prelude. Public domain code by Terry A. Davis.

Each source file is split into top-level chunks (functions, classes, globals,
directives). Chunks listed in EXCLUDE are dropped (they need x86, hardware,
the window manager or editor, or are provided natively/by the prelude); PATCHES
are small textual substitutions, each with a reason. Everything else is copied
verbatim, so the mobile runtime executes Terry's original graphics algorithms.

Usage: build_runtime_lib.py <templeos-iso dir> <out GrLib.HC>
"""
import re, sys

FILES = [
    'Adam/Gr/Gr.HH',
    'Adam/AMath.HC',
    'Adam/Gr/GrMath.HC',
    'Adam/Gr/GrBitMap.HC',
    'Adam/Gr/GrPrimatives.HC',
    'Adam/Gr/GrComposites.HC',
    'Adam/Gr/SpriteNew.HC',
    'Adam/Gr/GrSpritePlot.HC',
    'Adam/Gr/GrTextBase.HC',
    'Adam/AMathODE.HC',
    'Adam/ASnd.HC',
    'Adam/Menu.HC',
    'Adam/Ctrls/CtrlsA.HC',
    'Adam/Ctrls/CtrlsBttn.HC',
    'Adam/Ctrls/CtrlsSlider.HC',
    'Adam/Gr/SpriteEd.HC',
]

# For these files only the listed chunks are kept (the rest is editor UI).
INCLUDE_ONLY = {
    'Adam/Gr/SpriteEd.HC': {
        # sprite queue conversion and 4x4 transformation, used by programs (Demo/Games/Talons.HC)
        'Sprite2SpriteQue', 'SpriteQue2Sprite', 'SpriteTransformBitMap', 'SpriteTransformQue', 'SpriteQueSelAll',
        'SpriteTransform',
    },
}

# chunk names to drop, per file, with the reason
EXCLUDE = {
    'Adam/Gr/GrMath.HC': {
        # provided by the prelude (adapted from GrDC.HC/GrMath.HC)
        'Mat4x4MulMat4x4Equ', 'Mat4x4MulMat4x4New', 'Mat4x4Equ', 'Mat4x4New', 'Mat4x4RotX', 'Mat4x4RotY',
        'Mat4x4RotZ', 'Mat4x4Scale', 'DCThickScale', 'Mat4x4TranslationEqu', 'Mat4x4TranslationAdd',
        'DCSymmetrySet', 'DCSymmetry3Set', 'gr_x_offsets',
    },
    'Adam/Gr/GrBitMap.HC': {
        'GrPlot0', 'GrPeek0',            # native (hot path)
        'DCExt', 'DCDiff',               # need full heap/task semantics; DCExt re-added by prelude
    },
    'Adam/Gr/GrPrimatives.HC': {
        'GrFloodFillRay',                # native: the original needs a 16 MiB buffer per fill
    },
    'Adam/Gr/GrComposites.HC': {
        'GRScrnCaptureRead', 'GRScrnCaptureWrite',  # .GR file save of the real screen
    },
    'Adam/Menu.HC': {
        'DrawMenu', 'MenuTask',          # the host draws the menu bar natively
    },
    'Adam/Gr/SpriteNew.HC': {
        'SpriteElem2Summary',            # sprite editor UI text
    },
    'Adam/Gr/GrTextBase.HC': {
        'asm',                           # x86 text-layer blitters -> native TextChar & co.
        'TextChar', 'TextLenStr', 'TextLenAttrStr', 'TextLenAttr',
    },
}

# Chunks that use these identifiers are dropped automatically: they belong to
# the DolDoc document engine, the window manager, or hardware.
AUTO_EXCLUDE_USES = {
    'DocLock', 'DocUnlock', 'DocPut', 'CDoc', 'CDocEntry', 'DocPrint', 'DocSprite', 'DocEntryRun',
    'InU8', 'OutU8', 'PopUpForm', 'PopUpPickLst', 'DefineLstLoad', 'DefineSub', 'HashTableNew',
    'CCmpCtrl', 'LexExpressionI64', 'CmpCtrlNew', 'cpu_structs',
}

# Hot primitives implemented natively (kernel/Raster.kt). The original HolyC is
# kept, renamed NAME_HC, as the fallback for rare paths and as the reference
# for the differential test.
NATIVE_FAST = {'GrPlot', 'GrPlot1', 'GrPeek', 'GrRect', 'GrHLine', 'GrVLine', 'GrBlot', 'GrFillTri0', 'GrBlot3', 'DCReflect', 'GrLineFat3', 'GrFillCircle', 'GrFillSemiCircle', 'Line', 'SpriteElemSize', 'SpriteSize',
               # 2026-10-17 performance audit (docs/performance): GrCircle's arc walker, 36-61% of the VM
               # time of TreeCheckers, Pick3D and Span; GrPutChar, behind every GrPrint (score lines: 32%
               # of BomberGolf's draw_it, 15% of TreeCheckers')
               'Circle', 'GrPutChar'}

# (file, regex, replacement, reason)
PATCHES = [
    ('*', r'Option\(OPTf_[A-Z_]+,(ON|OFF)\);', '', 'compiler options are not modelled'),
    # An element type >= SPT_TYPES_NUM ends a sprite. The original walks on and
    # indexes sprite_elem_base_sizes out of bounds (undefined behaviour); the
    # ISO's Apps/Titanium/Titanium.HC has a sprite whose terminator byte is 0x38.
    ('*', r'while \((\w+)->type&SPG_TYPE_MASK\)', r'while (SpriteTypeOk(\1->type))', 'robust sprite walk'),
]


def strip_doldoc_links(s):
    # comments keep their text; $LK$ etc. are skipped by the lexer anyway
    return s


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return re.sub(r'\$[A-Z][A-Z][^$\n]*\$', ' ', s)


def split_chunks(text):
    """Split HolyC source into top-level chunks. Returns list of (name, text)."""
    chunks = []
    i, n = 0, len(text)
    start = 0
    depth = 0
    pdepth = 0
    seen_brace = False
    head = ''
    in_asm = False

    def name_of(chunk):
        c = strip_comments(chunk).strip()
        if c.startswith('#'):
            return '#'
        if re.match(r'^asm\b', c):
            return 'asm'
        m = re.search(r'\b(?:class|union)\s+([A-Za-z_\x80-\xff][\w\x80-\xff]*)', c.split('{')[0])
        if m and '(' not in c.split('{')[0]:
            return m.group(1)
        pre = c.split('{')[0] if '{' in c else c
        m = re.search(r'([A-Za-z_\x80-\xff][\w\x80-\xff]*)\s*\(', pre)
        if m and not re.search(r'=', pre.split('(')[0]):
            return m.group(1)
        m = re.findall(r'([A-Za-z_\x80-\xff][\w\x80-\xff]*)\s*(?:\[[^\]]*\])*\s*(?:=|,|;)', pre)
        return m[0] if m else c[:20]

    while i < n:
        ch = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if ch == '"' or ch == "'":
            q = ch
            i += 1
            while i < n and text[i] != q:
                if text[i] == '\\':
                    i += 1
                i += 1
            i += 1
            continue
        if ch == '$':
            j = text.find('$', i + 1)
            nl = text.find('\n', i + 1)
            if j > 0 and (nl < 0 or j < nl):
                i = j + 1
                continue
        if depth == 0 and pdepth == 0 and ch == '#' and text[start:i].strip() == '':
            j = text.find('\n', i)
            j = n if j < 0 else j
            chunks.append(text[start:j + 1])
            start = i = j + 1
            continue
        if ch == '(':
            pdepth += 1
        elif ch == ')':
            pdepth -= 1
        elif ch == '{':
            if depth == 0:
                head = strip_comments(text[start:i])
                seen_brace = True
                in_asm = bool(re.match(r'\s*asm\s*$', head.strip() and head.split('\n')[-1] or head)) or head.strip() == 'asm'
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                is_func = '(' in head and '=' not in head.split('(')[0] and not re.search(r'\b(class|union)\b', head)
                if is_func or head.strip() == 'asm' or in_asm:
                    chunks.append(text[start:i + 1])
                    start = i + 1
                    seen_brace = False
        elif ch == ';' and depth == 0 and pdepth == 0:
            chunks.append(text[start:i + 1])
            start = i + 1
            seen_brace = False
        i += 1
    if text[start:].strip():
        chunks.append(text[start:])
    return [(name_of(c), c) for c in chunks if c.strip()]


def main(root, out):
    parts = [
        '//Generated by tools/resource-packaging/build_runtime_lib.py - do not edit.',
        '//Original TempleOS V5.03 graphics library (public domain, Terry A. Davis),',
        '//from the official TempleOS.ISO (sha256 5d0fc944...). Excluded chunks are',
        '//listed in the tool with reasons.',
        '',
    ]
    protos = ['//---- forward declarations (TempleOS declares these in its kernel/Adam headers)']
    headers = []
    body = ['//---- TempleOS Mobile: see PATCHES in the generator',
            'Bool SpriteTypeOk(I64 type) {type&=SPG_TYPE_MASK; return 0<type<SPT_TYPES_NUM;}']
    for rel in FILES:
        if rel.endswith('.HH'):
            target = headers
        else:
            target = body
        raw = open(f'{root}/{rel}', 'rb').read().split(b'\0')[0].decode('latin-1')
        excl = EXCLUDE.get(rel, set())
        only = INCLUDE_ONLY.get(rel)
        if only is not None:
            # keep the listed chunks plus every chunk of this file they reference (transitively)
            chunks = dict(split_chunks(raw))
            only = set(only)
            todo = list(only)
            while todo:
                used = set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', strip_comments(chunks.get(todo.pop(), ''))))
                for n in used & set(chunks) - only:
                    only.add(n); todo.append(n)
        target.append(f'//==== {rel}')
        kept = dropped = 0
        for name, chunk in split_chunks(raw):
            if name in excl or (only is not None and name not in only):
                dropped += 1
                if only is None:
                    body.append(f'//[excluded: {name}]')
                continue
            used = set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', strip_comments(chunk)))
            hit = used & AUTO_EXCLUDE_USES
            if hit:
                dropped += 1
                body.append(f'//[excluded: {name} (uses {", ".join(sorted(hit))})]')
                continue
            for f, pat, rep, _why in PATCHES:
                if f in ('*', rel):
                    chunk = re.sub(pat, rep, chunk)
            if name in NATIVE_FAST:
                clean = strip_comments(chunk)
                head = re.sub(r'\s+', ' ', clean.split('{')[0].strip())
                protos.append('native ' + head + ';')
                chunk = re.sub(r'\b' + name + r'\s*\(', name + '_HC(', chunk, count=1)
            clean0 = strip_comments(chunk).strip()
            is_class = bool(re.match(r'^(public\s+)?((?:[IUF](?:8|16|32|64)i?|Bool)\s+)?(class|union)\b', clean0)) and '(' not in clean0.split('{')[0]
            (headers if is_class or clean0.startswith('#define') else target).append(chunk.strip('\n'))
            kept += 1
            clean = strip_comments(chunk)
            head = clean.split('{')[0].strip()
            if '{' in clean and '(' in head and not re.search(r'\b(class|union|asm)\b', head) and '=' not in head.split('(')[0]:
                protos.append(re.sub(r'\s+', ' ', head) + ';')
        print(f'{rel}: kept {kept}, excluded {dropped}')
    open(out, 'w', encoding='latin-1').write('\n'.join(parts + headers + protos + [''] + body) + '\n')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
