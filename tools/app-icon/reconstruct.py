"""Pixel-art reconstruction of the TempleOS app icon artwork (docs/app-icon/README.md).

The source (TempleOS.png) is a generated image that imitates pixel art: ~9.4 x 9.8 px
"cells" whose size and alignment drift across the canvas, ~80k distinct RGB values,
noisy cyan, soft cell borders and strings thinner than one cell. This module turns it
into genuine pixel art: one palette index per logical pixel.

  1. grid      edge-energy dynamic programming finds the column and row cuts of the
               cell grid; a Viterbi pass then lets every cut move up to 3 px per band
               of cells, which absorbs the drift without a rigid global grid
  2. palette   Lloyd iterations in CIELAB, started from the documented seed colors in
               icon_config.json, measure the actual colors of the artwork
  3. cells     every source pixel is snapped to the nearest palette color and every
               cell takes the majority color of its interior (border pixels, where the
               soft edges are, do not vote)
  4. rules     semantic repairs, each counted in the report:
               - thin-line rescue: dark lines thinner than a cell (the scale strings)
                 are skeletonized at source resolution and redrawn as 1-pixel lines
               - lettering: yellow inside the black lettering outline is the lettering
                 yellow, yellow anywhere else belongs to the gold ramp
               - outline repair: lettering yellow never touches a non-outline color
               - isolated low-confidence cells take their neighbors' color

Only Pillow and numpy are required. The output is deterministic.
"""
import numpy as np

# --------------------------------------------------------------------------- color

def srgb_to_lab(rgb):
    """sRGB (..., 3) in 0..255 -> CIELAB (D65)."""
    c = np.asarray(rgb, np.float64) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def nearest(lab, centers_lab):
    """Index of the nearest center (CIE76 distance) for every row of lab (..., 3)."""
    flat = lab.reshape(-1, 3)
    best = np.zeros(len(flat), np.int32)
    bestd = np.full(len(flat), np.inf)
    for k, c in enumerate(centers_lab):
        d = ((flat - c) ** 2).sum(1)
        better = d < bestd
        best[better], bestd[better] = k, d[better]
    return best.reshape(lab.shape[:-1])

# ---------------------------------------------------------------------------- grid

def edge_energy(a, axis):
    """Per-boundary edge strength: |RGB difference| between neighbors, thresholded and capped."""
    d = np.abs(np.diff(a, axis=axis)).sum(axis=2)
    return np.minimum(d, 240.0) * (d > 45)


def estimate_pitch(profile, lo=6.0, hi=14.0):
    """Dominant period of a boundary-energy profile (DFT magnitude scan)."""
    c = profile - profile.mean()
    n = np.arange(len(c))
    periods = np.arange(lo, hi, 0.01)
    mags = [abs((c * np.exp(2j * np.pi * n / p)).sum()) for p in periods]
    return float(periods[int(np.argmax(mags))])


def fit_cuts(S, pitch, lam):
    """Cut positions 0 = c0 < ... < cK = N maximizing sum S[c] - lam * sum (gap - pitch)^2.

    S[b] is the edge energy of boundary b (between pixels b-1 and b), len N+1.
    """
    N = len(S) - 1
    lo, hi = int(np.floor(pitch * 0.75)), int(np.ceil(pitch * 1.3))
    best = np.full(N + 1, -np.inf)
    prev = np.zeros(N + 1, int)
    best[0] = 0.0
    for b in range(1, N + 1):
        for d in range(lo, hi + 1):
            a0 = b - d
            if a0 < 0:
                break
            v = best[a0] + S[b] - lam * (d - pitch) ** 2
            if v > best[b]:
                best[b], prev[b] = v, a0
    if not np.isfinite(best[N]):           # canvas not a multiple of the allowed gaps: end with a short cell
        b = max(range(N - hi, N), key=lambda k: best[k])
        prev[N], best[N] = b, best[b]
    cuts, b = [N], N
    while b > 0:
        b = prev[b]
        cuts.append(b)
    return np.array(cuts[::-1])


def refine_cuts(cuts, bands, E, radius=3):
    """Let every cut move by up to `radius` px independently per band of cells.

    cuts: cut positions along the refined axis; bands: cut positions along the other
    axis; E: edge energy with shape (other axis, refined axis - 1). For each cut a
    Viterbi pass over the bands trades local edge energy against moving away from the
    global cut and against changing offset between neighboring bands.
    Returns R[band, k].
    """
    N = E.shape[1] + 1
    nb = len(bands) - 1
    Eb = np.zeros((nb, N + 1))
    for j in range(nb):
        Eb[j, 1:N] = E[bands[j]:bands[j + 1]].sum(axis=0)
    scale = Eb.max() + 1e-9
    mu, nu = 0.08 * scale, 0.02 * scale
    offs = np.arange(-radius, radius + 1)
    T = mu * np.abs(offs[:, None] - offs[None, :])
    R = np.zeros((nb, len(cuts)), int)
    for k, c in enumerate(cuts):
        if c in (0, N):
            R[:, k] = c
            continue
        pos = np.clip(c + offs, 1, N - 1)
        U = -Eb[:, pos] + nu * np.abs(offs)[None, :]
        cost, back = U[0].copy(), np.zeros((nb, len(offs)), int)
        for j in range(1, nb):
            tot = cost[:, None] + T
            back[j] = np.argmin(tot, axis=0)
            cost = tot[back[j], np.arange(len(offs))] + U[j]
        o = np.zeros(nb, int)
        o[-1] = int(np.argmin(cost))
        for j in range(nb - 1, 0, -1):
            o[j - 1] = back[j][o[j]]
        R[:, k] = pos[o]
    for j in range(nb):                    # keep cells at least 5 px wide
        for k in range(1, len(cuts)):
            R[j, k] = max(R[j, k], R[j, k - 1] + 5)
        R[j, -1] = N
    return R


class Grid:
    """Cell (i, j) covers x in [X[j, i], X[j, i+1]) and y in [Y[i, j], Y[i, j+1])."""

    def __init__(self, X, Y, xcuts, ycuts, pitch):
        self.X, self.Y, self.xcuts, self.ycuts, self.pitch = X, Y, xcuts, ycuts, pitch
        self.W, self.H = len(xcuts) - 1, len(ycuts) - 1

    def box(self, i, j, margin=0):
        x0, x1 = self.X[j, i], self.X[j, i + 1]
        y0, y1 = self.Y[i, j], self.Y[i, j + 1]
        m = margin if min(x1 - x0, y1 - y0) >= 3 + 2 * margin else 0
        return x0 + m, x1 - m, y0 + m, y1 - m

    def cell_of_pixel(self):
        """(H_px, W_px) arrays: the cell column and row of every source pixel (nominal cuts)."""
        return self.xcuts, self.ycuts


def infer_grid(a, pitch_range=(6.0, 14.0)):
    ex, ey = edge_energy(a, 1), edge_energy(a, 0)          # ex: (H, W-1), ey: (H-1, W)
    Sx = np.zeros(a.shape[1] + 1); Sx[1:-1] = ex.sum(0)
    Sy = np.zeros(a.shape[0] + 1); Sy[1:-1] = ey.sum(1)
    px, py = estimate_pitch(Sx, *pitch_range), estimate_pitch(Sy, *pitch_range)
    xcuts = fit_cuts(Sx, px, 0.15 * Sx.mean())
    ycuts = fit_cuts(Sy, py, 0.15 * Sy.mean())
    X = refine_cuts(xcuts, ycuts, ex)
    Y = refine_cuts(ycuts, xcuts, ey.T)
    return Grid(X, Y, xcuts, ycuts, (px, py))

# ------------------------------------------------------------------------- palette

def cell_medians(a, grid, margin=2):
    med = np.zeros((grid.H, grid.W, 3))
    spread = np.zeros((grid.H, grid.W))
    for j in range(grid.H):
        for i in range(grid.W):
            x0, x1, y0, y1 = grid.box(i, j, margin)
            blk = a[y0:y1, x0:x1].reshape(-1, 3)
            med[j, i] = np.median(blk, axis=0)
            spread[j, i] = np.sqrt(((blk - med[j, i]) ** 2).sum(1)).mean()
    return med, spread


def fit_palette(a, med, spread, seeds, iterations=25):
    """Measure the palette: Lloyd iterations in CIELAB over the uniform cells, from the seeds.

    seeds: list of dicts {name, family, rgb}. The first seed must be the background; it is
    measured over all background pixels. Returns (entries, stats) where entries carry the
    measured rgb and the number of cells that support them.
    """
    bg = np.array(seeds[0]['rgb'], float)
    lab_px = srgb_to_lab(a)
    bg_px = np.sqrt(((lab_px - srgb_to_lab(bg)) ** 2).sum(-1)) < 12
    bg_rgb = np.median(a[bg_px], axis=0)
    lab_cells = srgb_to_lab(med)
    is_bg = np.sqrt(((lab_cells - srgb_to_lab(bg_rgb)) ** 2).sum(-1)) < 12
    pure = (~is_bg) & (spread < 15)
    X = med[pure]
    XL = srgb_to_lab(X)
    centers = srgb_to_lab(np.array([s['rgb'] for s in seeds[1:]], float))
    for _ in range(iterations):
        lab_idx = nearest(XL, centers)
        new = centers.copy()
        for k in range(len(centers)):
            members = X[lab_idx == k]
            if len(members):
                new[k] = srgb_to_lab(np.median(members, axis=0))
        if np.allclose(new, centers):
            break
        centers = new
    lab_idx = nearest(XL, centers)
    entries = [dict(seeds[0], rgb=[int(round(v)) for v in bg_rgb], cells=int(is_bg.sum()))]
    for k, s in enumerate(seeds[1:]):
        members = X[lab_idx == k]
        if not len(members):
            continue                         # the artwork no longer uses this color
        rgb = np.median(members, axis=0)
        if s.get('snap') == 'black' and rgb.max() <= 8:
            rgb = np.zeros(3)
        entries.append(dict(s, rgb=[int(round(v)) for v in rgb], cells=int(len(members)),
                            spread=round(float(np.sqrt(((members - rgb) ** 2).sum(1)).mean()), 2)))
    return entries

# --------------------------------------------------------------------------- cells

def vote_cells(px_idx, grid, k, margin=1):
    """Majority palette index of every cell interior; also the winning share."""
    lab = np.zeros((grid.H, grid.W), np.int32)
    conf = np.zeros((grid.H, grid.W))
    for j in range(grid.H):
        for i in range(grid.W):
            x0, x1, y0, y1 = grid.box(i, j, margin)
            counts = np.bincount(px_idx[y0:y1, x0:x1].ravel(), minlength=k)
            lab[j, i] = int(np.argmax(counts))
            conf[j, i] = counts.max() / max(1, counts.sum())
    return lab, conf


def zhang_suen(mask):
    """Zhang-Suen thinning of a boolean image (numpy, iterative)."""
    img = np.pad(mask.astype(np.uint8), 1)
    while True:
        changed = False
        for step in (0, 1):
            p = img
            P2, P3, P4 = p[:-2, 1:-1], p[:-2, 2:], p[1:-1, 2:]
            P5, P6, P7 = p[2:, 2:], p[2:, 1:-1], p[2:, :-2]
            P8, P9 = p[1:-1, :-2], p[:-2, :-2]
            nb = [P2, P3, P4, P5, P6, P7, P8, P9]
            B = sum(n.astype(int) for n in nb)
            seq = nb + [P2]
            A = sum(((seq[i] == 0) & (seq[i + 1] == 1)).astype(int) for i in range(8))
            if step == 0:
                c = (P2 * P4 * P6 == 0) & (P4 * P6 * P8 == 0)
            else:
                c = (P2 * P4 * P8 == 0) & (P2 * P6 * P8 == 0)
            rm = (p[1:-1, 1:-1] == 1) & (B >= 2) & (B <= 6) & (A == 1) & c
            if rm.any():
                img = img.copy()
                img[1:-1, 1:-1][rm] = 0
                changed = True
        if not changed:
            return img[1:-1, 1:-1].astype(bool)


N8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
N4 = [(-1, 0), (1, 0), (0, -1), (0, 1)]


def components(mask, conn=N4):
    """Connected components of a small boolean grid: list of lists of (j, i)."""
    H, W = mask.shape
    seen = np.zeros_like(mask, bool)
    out = []
    for j in range(H):
        for i in range(W):
            if mask[j, i] and not seen[j, i]:
                comp, stack = [], [(j, i)]
                seen[j, i] = True
                while stack:
                    y, x = stack.pop()
                    comp.append((y, x))
                    for dy, dx in conn:
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
                out.append(comp)
    return out


def reconstruct(a, seeds, pitch_range=(6.0, 14.0)):
    """Full reconstruction. Returns dict with grid, palette entries, cell labels and a report."""
    report = {}
    grid = infer_grid(a, pitch_range)
    report['grid'] = {'pitch_px': [round(grid.pitch[0], 3), round(grid.pitch[1], 3)],
                      'cells': [grid.W, grid.H],
                      'mean_cell_px': [round(float(np.diff(grid.xcuts).mean()), 3),
                                       round(float(np.diff(grid.ycuts).mean()), 3)],
                      'refined_cut_moves': int((grid.X != grid.xcuts[None, :]).sum()
                                               + (grid.Y != grid.ycuts[None, :]).sum())}
    med, spread = cell_medians(a, grid)
    entries = fit_palette(a, med, spread, seeds)
    names = [e['name'] for e in entries]
    fam = {e['name']: e['family'] for e in entries}
    rgb = np.array([e['rgb'] for e in entries], float)
    pal_lab = srgb_to_lab(rgb)
    lab_px = srgb_to_lab(a)
    px_idx = nearest(lab_px, pal_lab)
    labels, conf = vote_cells(px_idx, grid, len(entries))
    report['uniform_cells'] = int((spread < 15).sum())
    report['straddling_cells'] = int((spread >= 20).sum())
    idx = {n: k for k, n in enumerate(names)}
    BG = 0
    H, W = labels.shape
    fixes = report.setdefault('fixes', {})

    # -- thin-line rescue: dark lines thinner than a cell (the scale strings)
    dark_ids = [idx[n] for n in names if fam[n] == 'line']
    L, C = lab_px[..., 0], np.hypot(lab_px[..., 1], lab_px[..., 2])
    dark_px = (L < 40) & (C < 25)
    skel = zhang_suen(dark_px)
    rescued = 0
    for j in range(H):
        for i in range(W):
            if labels[j, i] in dark_ids:
                continue
            x0, x1, y0, y1 = grid.box(i, j)
            s = skel[y0:y1, x0:x1]
            d = dark_px[y0:y1, x0:x1]
            if labels[j, i] == BG and s.sum() >= 2 and d.mean() >= 0.12:
                # black or the lighter line color, by the darkness of the line pixels in the cell
                Ld = L[y0:y1, x0:x1][d]
                darkest = min(dark_ids, key=lambda k: pal_lab[k][0])
                lightest = max(dark_ids, key=lambda k: pal_lab[k][0])
                labels[j, i] = darkest if np.median(Ld) < (pal_lab[darkest][0] + pal_lab[lightest][0]) / 2 else lightest
                rescued += 1
    fixes['thin_line_cells_rescued'] = rescued

    # -- lettering yellow vs gold yellow: flood fill from the lettering through yellow cells
    text_id = idx['text_yellow']
    yellowish = [idx[n] for n in names if fam[n] == 'gold' and pal_lab[idx[n]][0] > 88] + [text_id]
    is_y = np.isin(labels, yellowish)
    text_cells = np.zeros_like(is_y)
    for comp in components(is_y):
        n_text = sum(labels[p] == text_id for p in comp)
        if n_text >= 12 and n_text >= 0.5 * len(comp):
            for p in comp:
                text_cells[p] = True
    gold_ids = [idx[n] for n in names if fam[n] == 'gold']
    to_text = int((text_cells & (labels != text_id)).sum())
    labels[text_cells] = text_id
    stray = (labels == text_id) & ~text_cells
    for j, i in zip(*np.nonzero(stray)):                   # lettering yellow outside the lettering -> nearest gold
        labels[j, i] = min(gold_ids, key=lambda k: ((pal_lab[k] - pal_lab[text_id]) ** 2).sum())
    fixes['gold_to_lettering_yellow'] = to_text
    fixes['lettering_yellow_to_gold'] = int(stray.sum())

    # -- outline repair: lettering yellow only touches lettering yellow or the black outline
    black = min(dark_ids, key=lambda k: pal_lab[k][0])
    repaired = 0
    for j, i in zip(*np.nonzero(labels == text_id)):
        for dy, dx in N4:
            y, x = j + dy, i + dx
            if 0 <= y < H and 0 <= x < W and labels[y, x] not in (text_id, black):
                labels[y, x] = black
                repaired += 1
    fixes['outline_cells_repaired'] = repaired

    # -- clean pixel-art strings: drop L-corner cells (keeps lines 1 px wide, 8-connected)
    outline = np.zeros_like(labels, bool)
    for j, i in zip(*np.nonzero(labels == text_id)):
        for dy, dx in N8:
            y, x = j + dy, i + dx
            if 0 <= y < H and 0 <= x < W and labels[y, x] == black:
                outline[y, x] = True
    string = np.isin(labels, dark_ids) & ~outline
    removed = 0
    for j in range(1, H - 1):
        for i in range(1, W - 1):
            if not string[j, i]:
                continue
            nb = [(dy, dx) for dy, dx in N8 if string[j + dy, i + dx]]
            if len(nb) != 2:
                continue
            (ay, ax), (by, bx) = nb
            if {abs(ay) + abs(ax), abs(by) + abs(bx)} == {1} and abs(ay - by) == 1 and abs(ax - bx) == 1:
                # the two neighbors are one horizontal and one vertical step away and touch diagonally:
                # the cell is a redundant corner; it takes the color around it
                around = [labels[j + dy, i + dx] for dy, dx in N4 if not string[j + dy, i + dx]]
                labels[j, i] = max(set(around), key=around.count) if around else BG
                string[j, i] = False
                removed += 1
    fixes['string_corner_cells_removed'] = removed

    # -- a cell of another color family surrounded by one family (e.g. a white cell inside the
    #    gold roof) takes the nearest color of the surrounding family
    fam_of = np.array([e['family'] for e in entries])
    med_lab = srgb_to_lab(med)
    recolored = 0
    for j in range(1, H - 1):
        for i in range(1, W - 1):
            nf = {fam_of[labels[j + dy, i + dx]] for dy, dx in N8}
            f = fam_of[labels[j, i]]
            if len(nf) == 1 and f not in nf and f != 'line' and 'background' not in nf | {f}:
                target = nf.pop()
                cand = [k for k in range(len(entries)) if fam_of[k] == target]
                labels[j, i] = min(cand, key=lambda k: ((pal_lab[k] - med_lab[j, i]) ** 2).sum())
                recolored += 1
    fixes['cross_family_cells_recolored'] = recolored

    # -- isolated low-confidence cells take their neighbors' color
    cleaned = 0
    for j in range(1, H - 1):
        for i in range(1, W - 1):
            nb = [labels[j + dy, i + dx] for dy, dx in N8]
            if conf[j, i] < 0.6 and len(set(nb)) == 1 and nb[0] != labels[j, i] \
                    and labels[j, i] not in dark_ids:
                labels[j, i] = nb[0]
                cleaned += 1
    fixes['isolated_cells_cleaned'] = cleaned

    used = np.bincount(labels.ravel(), minlength=len(entries))
    for k, e in enumerate(entries):
        e['logical_pixels'] = int(used[k])
    return {'grid': grid, 'palette': entries, 'labels': labels, 'confidence': conf,
            'cell_medians': med, 'pixel_index': px_idx, 'report': report}
