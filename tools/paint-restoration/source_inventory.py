#!/usr/bin/env python3
"""Inventory the bundled original editor's menu surface and function boundaries.

This is a lexical audit index, not a claim of complete semantic or runtime coverage.
Originals are read only; statuses deliberately do not credit the mobile wrapper as an engine.
"""
import ast
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'shared/bundled-fs/Adam/Gr'
OUT = ROOT / 'docs/paint-restoration'

BITMAP = {
    'COLOR': 'Choose palette index; updates local color, returns to bitmap menu.',
    'DITHER_COLOR': 'Choose two indexed colors/ROPF_DITHER; updates color; returns to menu.',
    'WIDTH': 'Choose width in 1..16; updates width; returns to menu.',
    'PT': 'Left down calls GrPlot3 on img; does not start a continuous stroke.',
    'LINE': 'Left down anchors preview; move previews GrLine3; left up commits to img.',
    'ARROW': 'Same drag lifecycle as line using GrArrow3.',
    'RECT': 'Drag normalizes corners; commits FILLED GrRect with width/height INCLUDING last pixel.',
    'CIRCLE': 'Drag from center; radius is integer Euclidean distance; commits GrCircle3.',
    'TEXT': 'Get string in popup; pointer placement previews GrPrint; up commits.',
    'TEXT_BOX': 'Get string; pointer placement uses GrTextBox3; up commits.',
    'TEXT_DIAMOND': 'Get string; pointer placement uses GrTextDiamond3; up commits.',
    'FLOOD_FILL': 'Left down calls GrFloodFill(img,x-xx1,y-yy1).',
    'FLOOD_FILL_NOT': 'Left down calls GrFloodFill with not_color=TRUE (color barrier).',
    'POLYLINE': 'Successive clicks form connected lines; down flag remains set after up.',
    'POLYPT': 'Held left movement commits GrLine3 segments directly to img.',
    'COPY': 'Drag inclusive selection to a local CDC clipboard; leaves image intact.',
    'DELETE': 'Drag selection to clipboard; fill selected rectangle with bkcolor.',
    'PASTE': 'Preview/commit clip with DCF_NO_TRANSPARENTS, including transparent indices.',
    'PASTE_TRANSPARENT': 'Copy clip, change bkcolor to TRANSPARENT, then preview/commit GrBlot.',
    'FIND_AND_REPLACE': 'Choose find/replace indices; DCColorChg; return to menu.',
    'TRIM_TO_EXTENTS': 'Crop background/transparent edges, update xx1/yy1/xx2/yy2; minimum 1 pixel.',
    'ADD_OUTLINE': 'Choose width 1..16; snapshot per pass; add color to bkcolor pixels touching non-bkcolor in 8 neighbors.',
    'ETCH': 'Choose width 1..16; snapshot per pass; erase non-bkcolor pixels touching bkcolor OR outside in 8 neighbors.',
    'UNDO': 'Restore single CDC snapshot, DCDel it and clear pointer; no redo stack.',
    'SAVE_GR': 'DocForm filename then GRWrite(...,DCSF_COMPRESSED|DCSF_PALETTE_GET).',
    'MAIN_MENU': 'Return SPE_CONT to SMBitMap and the enclosing sprite workflow.',
    'EXIT': 'Return SPE_EXIT; caller commits bitmap to the sprite and exits sprite edit.',
}

MAIN = {
    'COLOR': 'Append SPT_COLOR record before insertion point; advance cursor.',
    'DITHER_COLOR': 'Append SPT_DITHER_COLOR record with two byte indices.',
    'THICK': 'Append thickness record from popup 1..16.',
    'PLANAR_SYMMETRY': 'Drag plane direction; append record; right release appends zero record to disable symmetry.',
    'PT': 'Append point at left-down coordinates minus sprite origin.',
    'LINE': 'SMLine drag -> SPT_LINE record; source raster on rendering.',
    'ARROW': 'SMArrow drag -> SPT_ARROW record.',
    'RECT': 'SMRect normalizes drag -> SPT_RECT corner record, interpreted by GrSpritePlot.',
    'CIRCLE': 'SMCircle drag center/radius -> circle record.',
    'ELLIPSE': 'SMEllipse uses staged axes/rotation input -> ellipse record.',
    'POLYGON': 'Choose sides 3..16 then SMPolygon staged geometry -> polygon record.',
    'POLYLINE': 'SMPolyLineFamily captures I32 point pairs.',
    'POLYPT': 'SMPolyPoint captures packed 3-bit relative direction steps.',
    'FLOOD_FILL': 'Append flood seed record; rendering depends on underlying destination pixels.',
    'FLOOD_FILL_NOT': 'Append inverse flood seed record; underlying destination matters.',
    'TEXT': 'SMTextFamily obtains text and placement; append text record.',
    'TEXT_BOX': 'SMTextFamily appends boxed text record.',
    'TEXT_DIAMOND': 'SMTextFamily appends diamond text record.',
    'BITMAP': 'Choose background/extents or existing bitmap; SMBitMap -> SpriteBitMapEd; replace/insert bitmap record.',
    'INS_SCRN_BITMAP': 'Drag screen region; SMScrnBitMap copies screen CDC -> bitmap record.',
    'INS_TRANSPARENT_SCRN_BITMAP': 'Choose key color then capture region and convert that index to TRANSPARENT.',
    'MESH': 'SMMesh -> SpriteMeshEd; replace/insert packed vertex/triangle mesh.',
    'SHIFTABLE_MESH': 'Choose origin; SMShiftableMesh -> SpriteMeshEd; translate vertices and store origin offset.',
    'TRANSFORM_ON': 'Append transform-on record affecting subsequent sprite elements.',
    'TRANSFORM_OFF': 'Append transform-off record affecting subsequent sprite elements.',
    'ED_MENU': 'Enter SpriteEd selection/transform/text workflow; return SPE_CONT/EXIT/ABORT.',
    'EXIT': 'SPE_EXIT; cleanup aliases, settings, title, linked list and temporary state.',
}
for name in ('BSPLINE2', 'BSPLINE3', 'BSPLINE2_CLOSED', 'BSPLINE3_CLOSED'):
    MAIN[name] = 'SMPolyLineFamily captures 3D control points for the selected open/closed B-spline type.'

EDIT = {
    'SEL_UNSEL_ALL': 'Toggle all selection flags.', 'SEL': 'Graphically select elements.',
    'SEL_RECTS': 'Select elements using rectangular regions.', 'UNSEL': 'Graphically clear selection.',
    'UNSEL_RECTS': 'Clear selection in rectangles.', 'SHIFT_PTS': 'Move individual control points.',
    'SHIFT_RECTS': 'Move points selected by rectangles.', 'SHIFT_SEL': 'Shift selected elements.',
    'TRANSFORM_SEL': 'Apply transform matrix to selected geometry.',
    'SET_ORIGIN': 'Rebase sprite coordinates/origin.', 'SHIFT_SUB_ORIGIN': 'Insert SPT_SHIFT before insertion point.',
    'TEXT_ED': 'SpriteQue2Sprite -> Sprite2Code -> editor -> SpriteCode2Sprite; validate replacement.',
    'INS_CLIP': 'Insert sprite records from clipboard.', 'MAIN_MENU': 'Return SPE_CONT.',
    'EXIT': 'Return SPE_EXIT.',
}


def c_strings(text):
    return ''.join(ast.literal_eval(m.group()) for m in re.finditer(r'"(?:\\.|[^"\\])*"', text))


def main():
    features = []
    sources = []
    for filename in ('SpriteMain.HC', 'SpriteBitMap.HC', 'SpriteEd.HC', 'SpriteMesh.HC',
                     'SpriteSideBar.HC', 'SpriteNew.HC', 'SpriteCode.HC', 'GrDC.HC'):
        path = SOURCE / filename
        data = path.read_bytes()
        text = data.decode('latin-1')
        functions = list(re.finditer(r'^(?:public )?(?:U0|Bool|I64|I32|U8|CDC|CSprite|CEdSprite|CMeshEdVertex|CMeshEdTri)\s*\**\s*(\w+)\s*\(', text, re.M))
        bounds = []
        for i, f in enumerate(functions):
            end = functions[i+1].start() if i+1 < len(functions) else len(text)
            bounds.append(dict(symbol=f[1], start=text.count('\n', 0, f.start())+1,
                               end=text.count('\n', 0, end),
                               lexical_calls=sorted(set(re.findall(r'\b([A-Z]\w+)\s*\(', text[f.end():end])))))
        sources.append(dict(path=str(path.relative_to(ROOT)), sha256=hashlib.sha256(data).hexdigest(), functions=bounds))
        for m in re.finditer(r'\$\$MU[^,]*,"([^"]*)",LE=([A-Z_0-9]+)\$\$', c_strings(text)):
            label, symbol = m.groups()
            if symbol == 'DOCM_CANCEL': behavior = 'Return SPE_ABORT; EdSpriteEd restores original resource; EdSpriteIns removes new entry.'
            elif symbol.startswith('SPBM_'): behavior = BITMAP.get(symbol[5:], 'Inspect dispatch branch.')
            elif symbol.startswith('SPED_'): behavior = EDIT.get(symbol[5:], 'Inspect SpriteEd dispatch branch.')
            elif symbol.startswith('SPT_'): behavior = MAIN.get(symbol[4:], 'Inspect SpriteMainEd dispatch branch.')
            else: behavior = 'Inspect dispatch branch.'
            at = text.find('LE=' + symbol)
            features.append(dict(id=filename + ':' + symbol, feature=label.replace('\x1f', ' '), symbol=symbol,
                source=str(path.relative_to(ROOT)), line=text.count('\n', 0, at)+1,
                original_input='Select this item from ' + filename.removesuffix('.HC') + ' menu; ' + ('right down reopens menu' if filename == 'SpriteBitMap.HC' else 'right release reopens main menu'),
                state_and_output=behavior,
                mobile_input='NOT IMPLEMENTED for historical editor',
                swift_terry='BLOCKED', swift_native='BLOCKED', kotlin_terry='BLOCKED', kotlin_native='BLOCKED',
                required_action='Restore original DolDoc entry/resource/menu APIs and translate original editor dependencies; then test this branch.'))
        if filename == 'SpriteMesh.HC':
            menu = text[text.index('  MenuPush('):text.index('  SettingsPush;')]
            for m in re.finditer(r'(\w+)\(([^)]*)\);', c_strings(menu)):
                label, keys = m.groups(); at = text.find(label+'(', text.index('  MenuPush('))
                features.append(dict(id='mesh:'+label+':'+keys, feature=label, symbol='SpriteMeshEd',
                    source=str(path.relative_to(ROOT)), line=text.count('\n',0,at)+1,
                    original_input='Mesh menu '+label+' or '+keys,
                    state_and_output='SpriteMeshEd key dispatch at lines 1085–1320; modifies CMeshFrame/vertices/triangles/view per command.',
                    mobile_input='NOT IMPLEMENTED for historical editor',
                    swift_terry='BLOCKED',swift_native='BLOCKED',kotlin_terry='BLOCKED',kotlin_native='BLOCKED',
                    required_action='Restore mesh dependencies and original input bindings, translate, and exercise the command.'))
    result = dict(scope='All statically named main/bitmap/edit/mesh menu commands. See SOURCE_SPEC.md for keyboard, sidebar, lifecycle and semantic audit limits.',
        historical_editor_available=False, features=features, sources=sources)
    OUT.mkdir(exist_ok=True)
    (OUT/'source-inventory.json').write_text(json.dumps(result,indent=2)+'\n')
    rows=['# Source menu verification matrix', '', 'Generated by `tools/paint-restoration/source_inventory.py`.', '',
          'All four historical editor targets are blocked before entry. A matching tool name in the mobile wrapper does not earn historical parity credit.', '',
          '| Feature | Source | Input / state / output | Original runtime | Swift Terry | Swift Native | Kotlin Terry | Kotlin Native |',
          '|---|---|---|---|---|---|---|---|']
    for f in features:
        src=f['source'].replace('shared/bundled-fs/','')+':'+str(f['line'])
        rows.append('| '+f['feature']+' | '+src+' | '+f['original_input']+'; '+f['state_and_output']+' | '+('PARTIAL (menu observed)' if f['source'].endswith(('SpriteMain.HC','SpriteBitMap.HC')) else 'NOT TESTED (source inspected)')+' | BLOCKED | BLOCKED | BLOCKED | BLOCKED |')
    (OUT/'FEATURE_MATRIX.md').write_text('\n'.join(rows)+'\n')
    print(f'{len(features)} menu operations; {sum(len(s["functions"]) for s in sources)} indexed functions')


if __name__ == '__main__':
    main()
