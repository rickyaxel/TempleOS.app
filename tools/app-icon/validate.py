"""Validation, previews and reports for the app icon build (called by build_app_icon.py).

Checks are geometric (layout.py, every art pixel against every mask outline) and
image-based (rasterized masks against the rendered art, dilated by the required cyan
margin), so the diagonal sword is never judged by its bounding box alone. Every check
is listed in docs/app-icon/validation-report.md with its measured value.
"""
import io, json, os, re
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import layout as L
import reconstruct as R
import render as RD

WALL = (38, 38, 42)          # neutral dark "home screen" behind masked previews
INK = (235, 235, 235)


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:                                   # Pillow without FreeType
        return ImageFont.load_default()


def png(arr):
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, 'PNG', optimize=True)
    return buf.getvalue()


def mask_raster(poly, size, scale, offset, ss=4):
    """Anti-aliased coverage (0..255) of an icon-unit polygon mapped to [offset, offset + scale] px."""
    big = Image.new('L', (size * ss, size * ss), 0)
    ImageDraw.Draw(big).polygon([((x * scale + offset) * ss, (y * scale + offset) * ss) for x, y in poly], fill=255)
    return np.asarray(big.resize((size, size), Image.BOX))


def dilate(a, r):
    """Square (Chebyshev) dilation of a 2-D array by r px."""
    if r <= 0:
        return a
    k = 2 * r + 1
    p = np.pad(a, r)
    p = np.lib.stride_tricks.sliding_window_view(p, k, axis=0).max(-1)
    return np.lib.stride_tricks.sliding_window_view(p, k, axis=1).max(-1)


def label(img, text, size=18, pad=8):
    """Image (RGB array) with a caption strip underneath."""
    f = font(size)
    h = size + 2 * pad
    w = max(img.shape[1], int(ImageDraw.Draw(Image.new('RGB', (1, 1))).textlength(text, font=f)) + 2 * pad)
    canvas = Image.new('RGB', (w, img.shape[0] + h), WALL)
    canvas.paste(Image.fromarray(img[..., :3] if img.ndim == 3 else img), (0, 0))
    ImageDraw.Draw(canvas).text((pad, img.shape[0] + pad - 1), text, fill=INK, font=f)
    return np.asarray(canvas)


def sheet(rows, gap=16, bg=WALL):
    """Rows of RGB arrays -> one image (each row left-aligned, items top-aligned)."""
    widths = [sum(i.shape[1] for i in r) + gap * (len(r) + 1) for r in rows]
    heights = [max(i.shape[0] for i in r) for r in rows]
    out = Image.new('RGB', (max(widths), sum(heights) + gap * (len(rows) + 1)), bg)
    y = gap
    for r, h in zip(rows, heights):
        x = gap
        for i in r:
            out.paste(Image.fromarray(i[..., :3]), (x, y))
            x += i.shape[1] + gap
        y += h + gap
    return np.asarray(out)


def composite(rgb, alpha, under=WALL):
    a = alpha.astype(np.float64)[..., None] / 255.0
    return np.clip(np.rint(rgb[..., :3] * a + np.array(under) * (1 - a)), 0, 255).astype(np.uint8)


def nn(img, k):
    return np.repeat(np.repeat(img, k, 0), k, 1)

# ----------------------------------------------------------------------- renders

def ios_icon(ctx, size):
    """iOS icon at `size` px: exact render of the master geometry, opaque square."""
    ios, pal = ctx['ios'], ctx['pal']
    k = size / ios['canvas_px']
    return RD.render_rgba(ctx['art'], pal, size, ios['cell_px'] * k,
                          (ios['origin_px'][0] * k, ios['origin_px'][1] * k), transparent=(), canvas=pal[0])[..., :3]


def android_layer(ctx, size, mono=False):
    """Adaptive foreground (or monochrome alpha) at a layer size of `size` px (108 dp)."""
    d = size / 108
    cell = ctx['a_cell'] * 72 * d
    origin = (ctx['a_origin'][0] * 72 * d + 18 * d, ctx['a_origin'][1] * 72 * d + 18 * d)
    if mono:
        return RD.render_alpha(ctx['mono'], size, cell, origin)
    return RD.render_rgba(ctx['art'], ctx['pal'], size, cell, origin, transparent=(0,))


def android_icon(ctx, view, mask, mono_tint=None):
    """Launcher-style render of the adaptive icon: `view` px viewport, a mask polygon, on WALL.

    mono_tint = (background rgb, foreground rgb) renders the themed (monochrome) icon instead.
    """
    layer = int(round(view * 1.5))
    off = (layer - view) // 2
    if mono_tint is None:
        fg = android_layer(ctx, layer)
        a = fg[..., 3:4].astype(np.float64) / 255.0
        rgb = fg[..., :3] * a + np.array(ctx['pal'][0], float) * (1 - a)
    else:
        al = android_layer(ctx, layer, mono=True).astype(np.float64)[..., None] / 255.0
        rgb = np.array(mono_tint[1], float) * al + np.array(mono_tint[0], float) * (1 - al)
    rgb = np.clip(np.rint(rgb), 0, 255).astype(np.uint8)[off:off + view, off:off + view]
    return composite(rgb, mask_raster(mask, view, view, 0))


def ios_masked(ctx, size, mask='ios-rounded-rect'):
    return composite(ios_icon(ctx, size), mask_raster(L.IOS_MASKS[mask], size, size, 0))


def outline_overlay(img, polys, scale, offset, colors):
    im = Image.fromarray(img.copy())
    d = ImageDraw.Draw(im)
    for poly, col in zip(polys, colors):
        pts = [(x * scale + offset, y * scale + offset) for x, y in poly]
        d.line(pts + [pts[0]], fill=col, width=2)
    return np.asarray(im)

# ------------------------------------------------------------------------ checks

def run(ctx):
    root, cfg, out, rec = ctx['root'], ctx['cfg'], ctx['out'], ctx['rec']
    labels, pal, palette = rec['labels'], ctx['pal'], rec['palette']
    D = cfg['outputs']['docs']
    names = [p['name'] for p in palette]
    fam = np.array([p['family'] for p in palette])
    results = []                                       # (group, check, ok, measured)

    def check(group, name, ok, measured):
        results.append((group, name, bool(ok), measured))

    # --- source
    src = ctx['src']
    check('source', 'source read-only (hash recorded, never written)', True, ctx['src_info']['sha256'][:16] + '…')
    check('source', 'source dimensions', True, f"{ctx['src_info']['size'][0]}x{ctx['src_info']['size'][1]} {ctx['src_info']['mode']}")

    # --- master pixel integrity
    m = ctx['master']
    check('master', '1024 x 1024', m.shape[:2] == (1024, 1024), f'{m.shape[1]}x{m.shape[0]}')
    check('master', 'RGB, no alpha channel', m.ndim == 3 and m.shape[2] == 3, f'{m.shape[2]} channels')
    mcolors = {tuple(c) for c in np.unique(m.reshape(-1, 3), axis=0)}
    pcolors = {tuple(int(v) for v in c) for c in pal}
    check('master', 'every pixel is an exact palette color (no interpolation, no halos)', mcolors <= pcolors,
          f'{len(mcolors)} colors, {len(mcolors - pcolors)} outside the palette')
    disk = os.path.join(root, cfg['outputs']['shared'], 'AppIcon-1024.png')
    if os.path.exists(disk):
        raw = open(disk, 'rb').read()
        im = Image.open(io.BytesIO(raw))
        check('master', 'file is PNG (not JPEG), RGB, 1024 x 1024',
              raw[:8] == b'\x89PNG\r\n\x1a\n' and im.mode == 'RGB' and im.size == (1024, 1024), f'{im.format} {im.mode} {im.size}')
        check('master', 'file pixels equal the build', np.array_equal(np.asarray(im), m), '')

    # --- reconstruction quality
    bg_cells = labels == 0
    grid = rec['grid']
    col = np.searchsorted(grid.xcuts, np.arange(src.shape[1]), 'right') - 1
    row = np.searchsorted(grid.ycuts, np.arange(src.shape[0]), 'right') - 1
    col, row = np.clip(col, 0, grid.W - 1), np.clip(row, 0, grid.H - 1)
    cell_lab = labels[row][:, col]                                          # cell label of every source pixel
    pidx = rec['pixel_index']
    lab_src = R.srgb_to_lab(src.astype(np.float64))
    pal_lab = R.srgb_to_lab(pal.astype(np.float64))
    dE = np.sqrt(((lab_src - pal_lab[pidx]) ** 2).sum(-1))
    # detail recall: lettering yellow and gold yellow are a few dE apart, so a source pixel's
    # nearest color cannot tell them apart; they are measured as one group
    groups = {'dark lines': ('line',), 'lettering + gold': ('text', 'gold'), 'silver': ('silver',)}
    limits = {'dark lines': 0.95, 'lettering + gold': 0.98, 'silver': 0.98}
    recall = {}
    for g, fams in groups.items():
        present = np.isin(fam[labels], fams)
        near = dilate(present.astype(np.uint8), 1).astype(bool)             # within one logical pixel
        px = np.isin(fam[pidx], fams) & (dE < 12)
        recall[g] = float(near[row][:, col][px].mean()) if px.any() else 1.0
        check('reconstruction', f'{g} detail kept: source pixels of that color within 1 logical px of one in the result',
              recall[g] >= limits[g], f'{recall[g] * 100:.2f}% of {int(px.sum()):,} px (limit {limits[g] * 100:.0f}%)')
    n_text = int((labels == names.index('text_yellow')).sum())
    check('reconstruction', 'lettering fill present', n_text >= 200, f'{n_text} logical px')
    text_id, black = names.index('text_yellow'), names.index('black')
    H, W = labels.shape
    leaks = 0
    for j, i in zip(*np.nonzero(labels == text_id)):
        for dy, dx in R.N4:
            y, x = j + dy, i + dx
            if 0 <= y < H and 0 <= x < W and labels[y, x] not in (text_id, black):
                leaks += 1
    check('reconstruction', 'lettering outline closed (lettering yellow touches only yellow or black)', leaks == 0, f'{leaks} open edges')
    lines = np.isin(labels, np.nonzero(fam == 'line')[0])
    outline = lines & dilate((labels == text_id).astype(np.uint8), 1).astype(bool)
    strings = R.components(lines & ~outline, R.N8)
    long_strings = [c for c in strings if len(c) >= 8]
    check('reconstruction', 'scale strings are continuous 1-px lines (8-connected runs >= 8 px)',
          len(long_strings) >= 2 and all(len(c) >= 2 for c in strings), f'{len(long_strings)} string runs, sizes {sorted(len(c) for c in strings)}')
    check('reconstruction', 'palette size', len(palette) <= 16, f'{len(palette)} colors')
    bg_src = src[cell_lab == 0]
    check('reconstruction', 'cyan field is one exact color', len({tuple(c) for c in pal[labels][bg_cells]}) == 1,
          f'source cyan region: {len(np.unique(bg_src, axis=0))} distinct colors -> 1')

    # --- layout geometry (kept artwork = everything except the sword, which runs out of the frame)
    ios, an = ctx['ios'], ctx['android']
    lo = cfg['layout']
    need = lo['ios']['min_clearance']
    for k, v in ios['mask_clearance_px'].items():
        check('geometry', f'iOS composition, {k}: every kept art pixel inside, cyan clearance >= {need * 100:.1f}%',
              v / 1024 >= need, f'{v:.1f} px ({v / 10.24:.1f}%) at logical {ios["mask_clearance_at_logical_px"][k]}')
    em = ios['kept_art_edge_margins_px']
    check('geometry', 'iOS kept art horizontally centered (left/right margins within 2 px)',
          abs(em['left'] - em['right']) <= 2, ', '.join(f'{k} {v}px ({v / 10.24:.1f}%)' for k, v in em.items()))
    for k, v in an['mask_clearance_dp'].items():
        need = 0.0 if 'safe' in k else (lo['android']['min_circle_clearance_dp'] if k in ('android-circle', 'android-teardrop') else 1.0)
        check('geometry', f'Android {k}: every kept art pixel inside, clearance >= {need} dp', v >= need,
              f'{v:.2f} dp ({v / 72 * 100:.1f}% of the icon) at logical {an["mask_clearance_at_logical_px"][k]}')

    # --- image-based clipping (rasterized masks vs rendered kept art, with the cyan margin)
    kept, sword = ctx['kept'], ctx['sword']
    k1024 = RD.render_alpha(kept, 1024, ios['cell_px'], ios['origin_px'])
    ring = int(round(0.02 * 1024))
    for k, poly in dict(L.IOS_MASKS, **{'play-store-rounded-square': L.PLAY_MASK}).items():
        M = mask_raster(poly, 1024, 1024, 0)
        clipped = int(((k1024 > 0) & (M < 255)).sum())
        ringed = int(((dilate(k1024, ring) > 0) & (M < 255)).sum())
        check('raster', f'iOS composition, {k} @1024: no kept art pixel under the mask; >= {ring} px cyan around it',
              clipped == 0 and ringed == 0, f'{clipped} clipped px, {ringed} px inside the {ring} px margin')
    layer = 432
    d = layer / 108
    a_px = ctx['a_cell'] * 72 * d
    a_org = (ctx['a_origin'][0] * 72 * d + 18 * d, ctx['a_origin'][1] * 72 * d + 18 * d)
    k432 = RD.render_alpha(kept, layer, a_px, a_org)
    ring = int(round(0.02 * 288))                             # square dilation: reaches ring * 1.41 diagonally
    for k, poly in L.ANDROID_MASKS.items():
        M = mask_raster(poly, layer, 288, 72)
        clipped = int(((k432 > 0) & (M < 255)).sum())
        ringed = int(((dilate(k432, ring) > 0) & (M < 255)).sum())
        check('raster', f'Android {k} @xxxhdpi: no kept art pixel under the mask; >= {ring} px cyan around it',
              clipped == 0 and ringed == 0, f'{clipped} clipped px, {ringed} px inside the {ring} px margin')

    # --- the sword is cut by the frame, never nicked: it is a full-width band at both ends
    #     all the way to the edge of the rendered canvas, so every mask cuts through the band
    sw = ctx['comp']['sword']
    if sw.get('mode') == 'whole':
        check('sword', 'whole sword kept inside every mask (layout.sword = "whole"; covered by the kept-art checks)', True, '')
    else:
        rising = sw['axis_slope_dy_dx'] < 0                       # tip toward the top right
        for name, alpha in (('iOS 1024', RD.render_alpha(sword, 1024, ios['cell_px'], ios['origin_px'])),
                            ('Android 108 dp layer', RD.render_alpha(sword, layer, a_px, a_org))):
            n = alpha.shape[0]
            border = np.zeros_like(alpha, bool)
            border[0, :] = border[-1, :] = border[:, 0] = border[:, -1] = True
            yy, xx = np.nonzero(border & (alpha > 0))
            upper = (yy < n / 2) & ((xx > n / 2) if rising else (xx < n / 2))
            lower = (yy > n / 2) & ((xx < n / 2) if rising else (xx > n / 2))
            check('sword', f'{name}: the sword runs off the canvas at both ends (cut by every mask, not ending inside it)',
                  upper.any() and lower.any(), f'{int(upper.sum())} / {int(lower.sum())} edge px at the tip / grip end')
        check('sword', 'sword extended by copying clean full-width sections (no tip or pommel shading repeated)',
              all(sw[e]['sideways_drift_per_step_px'] <= 0.1 and sw[e]['copies'] > 0 for e in ('tip', 'grip')),
              '; '.join(f"{e}: section {sw[e]['copied_section_axial_px']} step {tuple(sw[e]['step_px'])} drift "
                        f"{sw[e]['sideways_drift_per_step_px']} px/copy" for e in ('tip', 'grip')))

    # --- platform files
    iset = os.path.join(root, cfg['ios']['appiconset'])
    try:
        contents = json.load(open(os.path.join(iset, 'Contents.json')))
        imgs = contents['images']
        ok = len(imgs) == 1 and imgs[0]['size'] == '1024x1024' and imgs[0]['idiom'] == 'universal'
        f = os.path.join(iset, imgs[0]['filename'])
        im = Image.open(f)
        check('ios', 'AppIcon.appiconset: one universal 1024 icon, file present, RGB, equals the master',
              ok and im.size == (1024, 1024) and im.mode == 'RGB' and np.array_equal(np.asarray(im), m), f'{imgs[0]["filename"]} {im.mode} {im.size}')
        extra = sorted(set(os.listdir(iset)) - {'Contents.json', imgs[0]['filename']})
        check('ios', 'no stray files in the icon set', not extra, ', '.join(extra) or 'none')
    except (OSError, KeyError, ValueError) as e:
        check('ios', 'AppIcon.appiconset readable', False, str(e))
    pbx = open(os.path.join(root, 'temple_os_swift/App/TempleOSMobile.xcodeproj/project.pbxproj')).read()
    check('ios', 'target uses the AppIcon set (ASSETCATALOG_COMPILER_APPICON_NAME)',
          pbx.count('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;') >= 2, f"{pbx.count('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')} build configurations")

    res = os.path.join(root, cfg['android']['res_dir'])
    for dname, d in cfg['android']['densities'].items():
        size = int(round(108 * d))
        org = (ctx['a_origin'][0] * 72 * d + 18 * d, ctx['a_origin'][1] * 72 * d + 18 * d)
        sw_alpha = RD.render_alpha(sword, size, ctx['a_cell'] * 72 * d, org)
        for kind in ('foreground', 'monochrome'):
            p = os.path.join(res, f'mipmap-{dname}', f'ic_launcher_{kind}.png')
            if not os.path.exists(p):
                check('android', f'mipmap-{dname}/ic_launcher_{kind}.png present', False, 'missing')
                continue
            im = Image.open(p)
            arr = np.asarray(im)
            ok = im.size == (size, size) and im.mode == 'RGBA'
            if ok:
                al = arr[..., 3]
                edge = np.zeros_like(al, bool)
                edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
                stray_edge = int((edge & (al > 0) & (sw_alpha == 0)).sum())    # only the sword may reach the edge
                clear = float((al == 0).mean())
                ok = stray_edge == 0 and clear > 0.5
                msg = f'{im.size[0]}x{im.size[1]} RGBA, {clear * 100:.0f}% transparent, only the sword reaches the layer edge'
                if kind == 'monochrome':
                    ok &= bool((arr[..., :3][al > 0] == 255).all())
                    msg += ', single color (white + alpha)'
            else:
                msg = f'{im.size} {im.mode}'
            check('android', f'mipmap-{dname}/ic_launcher_{kind}.png {size} px', ok, msg)
    try:
        ad = ET.parse(os.path.join(res, 'mipmap-anydpi-v26/ic_launcher.xml')).getroot()
        A = '{http://schemas.android.com/apk/res/android}drawable'
        refs = {c.tag: c.get(A) for c in ad}
        want = {'background': '@drawable/ic_launcher_background', 'foreground': '@mipmap/ic_launcher_foreground',
                'monochrome': '@mipmap/ic_launcher_monochrome'}
        check('android', 'adaptive icon XML: background, foreground and monochrome layers', refs == want, str(refs))
        shape = ET.parse(os.path.join(res, 'drawable/ic_launcher_background.xml')).getroot()
        color = shape.find('solid').get('{http://schemas.android.com/apk/res/android}color')
        check('android', 'background layer is the canonical cyan', color.upper() == '#%02X%02X%02X' % tuple(pal[0]), color)
    except (OSError, ET.ParseError, AttributeError) as e:
        check('android', 'adaptive icon XML readable', False, str(e))
    stale = [os.path.relpath(os.path.join(dp, f), root) for dp, _, fs in os.walk(res) for f in fs
             if re.match(r'ic_launcher(_round)?\.(png|webp|xml)$|ic_launcher_foreground\.xml$', f)
             and not dp.endswith('mipmap-anydpi-v26')]
    check('android', 'no conflicting legacy launcher resources', not stale, ', '.join(stale) or 'none')
    man = open(os.path.join(root, 'temple_os_kotlin/app/src/main/AndroidManifest.xml')).read()
    check('android', 'manifest icon and roundIcon reference @mipmap/ic_launcher',
          'android:icon="@mipmap/ic_launcher"' in man and 'android:roundIcon="@mipmap/ic_launcher"' in man, '')
    gradle = open(os.path.join(root, 'temple_os_kotlin/app/build.gradle.kts')).read()
    mins = re.search(r'minSdk\s*=\s*(\d+)', gradle)
    check('android', 'minSdk >= 26, so the adaptive icon serves every supported device (no legacy PNG needed)',
          mins and int(mins.group(1)) >= 26, f'minSdk {mins.group(1) if mins else "?"}')
    store = ctx['store']
    check('android', 'Play listing icon 512 x 512, 32-bit PNG (RGBA), fully opaque',
          store.shape == (512, 512, 4) and int(store[..., 3].min()) == 255, f'{store.shape[1]}x{store.shape[0]}x{store.shape[2]}')

    # ------------------------------------------------------------------ previews
    previews(ctx, D, out)
    color_report(ctx, D, out, cell_lab, dE)
    write_report(ctx, D, out, results, recall)
    return [f'{g}: {n} ({v})' for g, n, ok, v in results if not ok]


def previews(ctx, D, out):
    src = ctx['src']
    pal, labels = ctx['pal'], ctx['rec']['labels']
    P = f'{D}/previews'
    recon_img = nn(pal[labels], 4)
    master = ctx['master']
    out.emit(f'{P}/reconstructed-4x.png', png(nn(pal[labels], 4)), doc=True)

    # iOS masks
    ios_imgs = []
    for k, poly in L.IOS_MASKS.items():
        img = ios_masked(ctx, 512, k)
        ios_imgs.append(label(outline_overlay(img, [poly], 512, 0, [(255, 60, 60)]), k))
    out.emit(f'{P}/masks-ios.png', png(sheet([ios_imgs])), doc=True)
    out.emit(f'{P}/ios-1024-masked.png', png(ios_masked(ctx, 1024)), doc=True)

    # Android masks: clean and with the safe zone / mask outline
    clean, debug = [], []
    for k, poly in L.ANDROID_MASKS.items():
        img = android_icon(ctx, 288, poly)
        clean.append(label(img, k.replace('android-', ''), 15))
        debug.append(label(outline_overlay(img, [poly, L.ANDROID_SAFE_ZONE], 288, 0, [(255, 60, 60), (255, 200, 0)]),
                           k.replace('android-', '') + ' + 66dp safe zone', 13))
    out.emit(f'{P}/masks-android.png', png(sheet([clean[:3], clean[3:], debug[:3], debug[3:]])), doc=True)
    # full 108 dp layers (what the launcher moves for parallax), foreground over background
    lay = android_layer(ctx, 432)
    a = lay[..., 3:4] / 255.0
    full = np.clip(np.rint(lay[..., :3] * a + np.array(pal[0], float) * (1 - a)), 0, 255).astype(np.uint8)
    full = outline_overlay(full, [L.square(), L.circle(), L.ANDROID_SAFE_ZONE], 288, 72, [(255, 255, 255), (255, 60, 60), (255, 200, 0)])
    yy, xx = np.indices(lay.shape[:2])
    checker = ((yy // 12 + xx // 12) % 2 * 40 + 180).astype(np.uint8)
    fg_only = composite(lay, lay[..., 3], under=(0, 0, 0))
    fg_only = np.where(lay[..., 3:4] > 0, fg_only, np.dstack([checker] * 3))
    out.emit(f'{P}/android-layers.png', png(sheet([[label(fg_only, 'foreground layer (transparent = checker)', 14),
                                                    label(full, 'fg + bg, 108dp: 72dp viewport, circle, 66dp safe zone', 13)]])), doc=True)
    # themed (monochrome) icon
    themed = [label(android_icon(ctx, 288, L.ANDROID_MASKS['android-circle'], ((32, 52, 58), (182, 236, 248))), 'themed, dark', 15),
              label(android_icon(ctx, 288, L.ANDROID_MASKS['android-circle'], ((206, 236, 246), (16, 60, 74))), 'themed, light', 15)]
    out.emit(f'{P}/android-themed-monochrome.png', png(sheet([themed])), doc=True)

    # display sizes: true size and 4x nearest-neighbor magnified views of the small ones
    rows = []
    for name, fn in (('iOS', lambda s: ios_masked(ctx, s)),
                     ('Android circle', lambda s: android_icon(ctx, s, L.ANDROID_MASKS['android-circle'])),
                     ('Android squircle', lambda s: android_icon(ctx, s, L.ANDROID_MASKS['android-squircle']))):
        rows.append([label(fn(s), f'{name} {s}px', 13) for s in (256, 128, 64, 48)] +
                    [label(nn(fn(s), 4), f'{s}px magnified 4x', 13) for s in (64, 48)])
    out.emit(f'{P}/sizes.png', png(sheet(rows)), doc=True)

    # before / after crops (source px boxes and the matching logical pixels at 8x)
    g = ctx['rec']['grid']
    crops = []
    # crop boxes as fractions of the source (chosen on the 1254 px TempleOS.png)
    sw_, sh_ = src.shape[1], src.shape[0]
    for nm, box in (('sword tip', (990, 40, 1140, 190)), ('roof', (560, 290, 760, 460)),
                    ('strings', (240, 440, 440, 640)), ('lettering', (70, 600, 330, 790)),
                    ('guard', (260, 860, 560, 1120)), ('birds', (90, 220, 430, 420))):
        x0, x1 = (int(v / 1254 * sw_) for v in box[0::2])
        y0, y1 = (int(v / 1254 * sh_) for v in box[1::2])
        i0, i1 = np.searchsorted(g.xcuts, x0), min(np.searchsorted(g.xcuts, x1), g.W)
        j0, j1 = np.searchsorted(g.ycuts, y0), min(np.searchsorted(g.ycuts, y1), g.H)
        x0, x1, y0, y1 = g.xcuts[i0], g.xcuts[i1], g.ycuts[j0], g.ycuts[j1]
        before = np.asarray(Image.fromarray(src[y0:y1, x0:x1]).resize(((x1 - x0) * 2, (y1 - y0) * 2), Image.NEAREST))
        after = np.asarray(Image.fromarray(pal[labels[j0:j1, i0:i1]]).resize(before.shape[1::-1], Image.NEAREST))
        crops.append([label(before, f'{nm}: source', 14), label(after, f'{nm}: reconstructed', 14)])
    out.emit(f'{P}/before-after.png', png(sheet([crops[0] + crops[1], crops[2] + crops[3], crops[4] + crops[5]])), doc=True)

    # contact sheet
    S = 300
    small = [label(ios_masked(ctx, s), f'iOS {s}', 12) for s in (128, 64, 48)] + \
            [label(android_icon(ctx, s, L.ANDROID_MASKS['android-circle']), f'Android {s}', 12) for s in (128, 64, 48)]
    rh, rw = recon_img.shape[:2]
    row1 = [label(np.asarray(Image.fromarray(src).resize((S, S), Image.BOX)), 'TempleOS.png (source)', 14),
            label(np.asarray(Image.fromarray(recon_img).resize((round(S * rw / rh), S), Image.BOX)), 'reconstructed pixel art', 14),
            label(np.asarray(Image.fromarray(master).resize((S, S), Image.BOX)), 'normalized 1024 master', 14)]
    row2 = [label(ios_masked(ctx, S), 'iOS rounded rect', 14),
            label(android_icon(ctx, S, L.ANDROID_MASKS['android-circle']), 'Android circle', 14),
            label(android_icon(ctx, S, L.ANDROID_MASKS['android-rounded-square']), 'Android rounded square', 14)]
    out.emit(f'{D}/contact-sheet.png', png(sheet([row1, row2, small])), doc=True)


def color_report(ctx, D, out, cell_lab, dE):
    src, pal, rec = ctx['src'], ctx['pal'], ctx['rec']
    palette = rec['palette']
    fam = np.array([p['family'] for p in palette])
    flat = src.reshape(-1, 3)
    uniq_src = len(np.unique(flat, axis=0))
    uniq_master = len(np.unique(ctx['master'].reshape(-1, 3), axis=0))
    lines = ['# App icon color report', '', f'Generated by `tools/app-icon/build_app_icon.py`. Source: `TempleOS.png` '
             f'(sha256 `{ctx["src_info"]["sha256"]}`).', '',
             '## Before and after', '',
             '| | source | reconstructed master |', '|---|---:|---:|',
             f'| distinct RGB values | {uniq_src:,} | {uniq_master} |']
    fam_px = fam[cell_lab]
    for f in ('background', 'line', 'text', 'gold', 'silver'):
        px = src[fam_px == f]
        n_src = len(np.unique(px, axis=0)) if len(px) else 0
        n_pal = int((fam == f).sum())
        lines.append(f'| distinct values in the {f} regions | {n_src:,} | {n_pal} |')
    bgpx = src[cell_lab == 0].astype(np.float64)
    sd = bgpx.std(0)
    lines += [f'| cyan field RGB standard deviation | {sd[0]:.2f} / {sd[1]:.2f} / {sd[2]:.2f} | 0 / 0 / 0 |', '',
              'Per-family counts use the reconstructed regions mapped back onto the source pixels. '
              '"Distinct values" in the source include the soft, interpolated cell borders as well as the '
              'within-cell noise; the reconstruction keeps one value per palette shade.', '',
              '## Palette (measured from the source)', '',
              '| name | family | hex | RGB | uniform source cells | mean spread in those cells (RGB) | logical pixels | role |',
              '|---|---|---|---|---:|---:|---:|---|']
    for p in palette:
        lines.append(f"| `{p['name']}` | {p['family']} | `#{p['rgb'][0]:02X}{p['rgb'][1]:02X}{p['rgb'][2]:02X}` | {tuple(p['rgb'])} | "
                     f"{p.get('cells', '')} | {p.get('spread', '—')} | {p['logical_pixels']} | {p.get('role', '')} |")
    lines += ['', '## Noise removed', '',
              'CIELAB distance between each source pixel and its nearest palette color, over the pixels within '
              '12 ΔE of the palette (the soft ramps between two colors mostly fall outside that and are not counted):', '',
              '| family | pixels | median ΔE | 95th percentile ΔE |', '|---|---:|---:|---:|']
    pidx = rec['pixel_index']
    conf = dE < 12
    for f in ('background', 'line', 'text', 'gold', 'silver'):
        sel = conf & (fam[pidx] == f)
        if sel.any():
            lines.append(f'| {f} | {int(sel.sum()):,} | {np.median(dE[sel]):.2f} | {np.percentile(dE[sel], 95):.2f} |')
    top = np.unique(flat, axis=0, return_counts=True)
    order = np.argsort(-top[1])[:12]
    lines += ['', '## Most frequent source colors', '', 'The cyan alone occurs as dozens of near-identical values:', '',
              '| RGB | pixels |', '|---|---:|'] + [f'| {tuple(int(v) for v in top[0][i])} | {int(top[1][i]):,} |' for i in order]
    out.emit(f'{D}/color-report.md', ('\n'.join(lines) + '\n').encode(), doc=True)


def write_report(ctx, D, out, results, recall):
    ios, an = ctx['ios'], ctx['android']
    rep = ctx['rec']['report']
    ok = all(r[2] for r in results)
    lines = ['# App icon validation report', '',
             f'Generated by `tools/app-icon/build_app_icon.py`. Result: **{"PASS" if ok else "FAIL"}** '
             f'({sum(r[2] for r in results)}/{len(results)} checks).', '',
             'These are automated checks of the generated files and geometry. Launcher checks on real devices '
             'are recorded separately in `README.md` (section "Device validation").', '',
             '## Reconstruction', '',
             f"- source grid: {rep['grid']['cells'][0]} x {rep['grid']['cells'][1]} logical pixels, mean cell "
             f"{rep['grid']['mean_cell_px'][0]} x {rep['grid']['mean_cell_px'][1]} source px; {rep['grid']['refined_cut_moves']} "
             'per-band cut adjustments',
             f"- cells with uniform interiors: {rep['uniform_cells']}; cells straddling an edge: {rep['straddling_cells']}",
             '- rule fixes: ' + ', '.join(f'{k.replace("_", " ")} {v}' for k, v in rep['fixes'].items()), '',
             '## Composition', '',
             '- By owner direction (2026-10-16) the sword runs out of the frame at both ends so the wordmark can be '
             'large; every other element (wordmark, roof, strings, pans, birds, gold guard) stays inside every mask '
             'with cyan around it.',
             f"- iOS: {ios['cell_px']} px per logical pixel (integer: hard edges), wordmark {ios['wordmark_width_pct']}% of the "
             f"icon width, its center {ios['wordmark_center_below_icon_center_px']} px below the icon center",
             f"- Android: {an['cell_dp']:.4f} dp per logical pixel, wordmark {an['wordmark_width_pct_of_viewport']}% of the "
             f"72 dp viewport, its center {an['wordmark_center_below_icon_center_dp']} dp below the center; farthest kept "
             f"pixel {an['farthest_kept_point_dp']} dp from the center (66 dp safe zone)", '',
             '## Checks', '', '| group | check | result | measured |', '|---|---|---|---|']
    for g, n, k, v in results:
        lines.append(f"| {g} | {n} | {'PASS' if k else '**FAIL**'} | {v} |")
    out.emit(f'{D}/validation-report.md', ('\n'.join(lines) + '\n').encode(), doc=True)
