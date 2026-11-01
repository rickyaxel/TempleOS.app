"""Icon composition: the sword runs out of the frame so the TempleOS wordmark can be large.

The full artwork cannot be scaled up without the diagonal sword's tip and grip meeting the
launcher masks. By owner direction (2026-10-16) the sword is deliberately clipped: it is
continued past both ends of the frame, so every mask cuts it through the full-width blade
and grip (a clean bleed) instead of nicking the tip. Everything else (wordmark, roof,
strings, pans, birds and the gold guard) must stay fully inside every mask with cyan around it.

Extending the sword stays pixel art: a clean section of the blade (and of the grip) is
copied outward by an integer step vector (dx, dy) parallel to the sword. The step is chosen
so its sideways drift is negligible (0.008 logical px per copy for the blade), so the
copies tile the band exactly: same staircase edges, same shading columns, no seams.
"""
import itertools
import numpy as np

from reconstruct import components, N8

END_CAP_MARGIN = 4      # logical px kept away from the tip point and the pommel when copying


def find_sword(labels, fam, share=0.25):
    """The sword: the silver components of at least `share` of the largest one. The sword is
    split into large pieces by the roof, wordmark and guard (198-421 logical px here); the birds
    are small silver components (16-38 px)."""
    sword = np.zeros(labels.shape, bool)
    comps = components(fam[labels] == 'silver', N8)
    biggest = max((len(c) for c in comps), default=0)
    for comp in comps:
        if len(comp) >= max(40, share * biggest):
            for p in comp:
                sword[p] = True
    if not sword.any():
        raise SystemExit('no sword found in the reconstructed artwork')
    return sword


def _axis(mask):
    ys, xs = np.nonzero(mask)
    P = np.column_stack([xs + 0.5, ys + 0.5])
    m = P.mean(0)
    u = np.linalg.svd(P - m)[2][0]
    return m, u / np.linalg.norm(u)


def _step(u, lo, hi):
    """Integer step (dx, dy) along u, length in [lo, hi], with the least sideways drift."""
    n = np.array([-u[1], u[0]])
    best = None
    for dx, dy in itertools.product(range(-int(hi) - 1, int(hi) + 2), repeat=2):
        v = np.array([dx, dy], float)
        length = np.hypot(dx, dy)
        if not lo <= length <= hi or v @ u <= 0:
            continue
        key = (round(abs(v @ n), 6), length)
        if best is None or key < best[0]:
            best = (key, (dx, dy))
    return best[1]


def extend_sword(labels, fam, pad):
    """Pad the logical canvas by `pad` on every side and continue the sword to the canvas edge.

    Returns (canvas labels, sword mask on the canvas, report dict).
    """
    sword = find_sword(labels, fam)
    H, W = labels.shape
    L = np.zeros((H + 2 * pad, W + 2 * pad), labels.dtype)
    L[pad:pad + H, pad:pad + W] = labels
    S = np.zeros(L.shape, bool)
    S[pad:pad + H, pad:pad + W] = sword
    m, u = _axis(S)
    gold = fam[L] == 'gold'
    ys, xs = np.nonzero(S)
    t_all = (np.column_stack([xs + 0.5, ys + 0.5]) - m) @ u
    # the tip is the end away from the gold guard
    gy, gx = np.nonzero(gold & ~S)
    near = [(y, x) for y, x in zip(gy, gx) if S[max(0, y - 1):y + 2, max(0, x - 1):x + 2].any()]
    guard_t = np.mean([(np.array([x + 0.5, y + 0.5]) - m) @ u for y, x in near]) if near else -1.0
    if guard_t > 0:
        u = -u
        t_all = -t_all
    n = np.array([-u[1], u[0]])
    other = (L != 0) & ~S
    pad_other = np.pad(other, 1)
    touch_cell = np.zeros(len(ys), bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            touch_cell |= pad_other[ys + 1 + dy, xs + 1 + dx]
    perp = (np.column_stack([xs + 0.5, ys + 0.5]) - m) @ n
    bins = np.floor(t_all / 2) * 2
    w, touching = {}, {}
    for b in np.unique(bins):
        sel = bins == b
        w[b] = perp[sel].max() - perp[sel].min() + 1
        touching[b] = bool(touch_cell[sel].any())
    report = {'axis_slope_dy_dx': round(float(u[1] / u[0]), 4), 'canvas_pad': pad}
    for end, name in ((+1, 'tip'), (-1, 'grip')):
        # outermost run of bins not touching other art, walking in from this end
        run = []
        for b in sorted((b for b in w if b * end > 0), reverse=end > 0):
            if touching[b]:
                break
            run.append(b)
        if not run:
            raise SystemExit(f'the sword {name} touches other artwork; nothing to extend from')
        ref = float(np.median([w[b] for b in run]))
        ok = []
        for b in run:                                   # skip the taper (tip point / pommel) ...
            if w[b] >= 0.85 * ref:
                ok.append(b)
            elif ok:                                    # ... and stop at the first narrow bin after it
                break
        lo, hi = min(ok), max(ok) + 2                   # clean, full-width axial interval,
        if end > 0:                                     # minus a margin at the end cap so no
            hi -= END_CAP_MARGIN                        # shading of the tip or pommel is copied
        else:
            lo += END_CAP_MARGIN
        T = _step(u * end, 5, min(24.0, hi - lo))
        Tlen = abs(np.array(T, float) @ u)
        a, b = (hi - Tlen, hi) if end > 0 else (lo, lo + Tlen)
        ys, xs = np.nonzero(S)
        t = (np.column_stack([xs + 0.5, ys + 0.5]) - m) @ u
        sec = (t >= a) & (t < b)
        cells = [(y, x, L[y, x]) for y, x in zip(ys[sec], xs[sec])]
        beyond = (t >= b) if end > 0 else (t < a)
        L[ys[beyond], xs[beyond]] = 0                    # drop the original tip / pommel
        S[ys[beyond], xs[beyond]] = False
        k = 1
        while True:
            placed = False
            for y, x, v in cells:
                ny, nx = y + k * T[1], x + k * T[0]
                if 0 <= ny < L.shape[0] and 0 <= nx < L.shape[1]:
                    placed = True
                    if L[ny, nx] == 0:                   # never paint over other artwork
                        L[ny, nx] = v
                        S[ny, nx] = True
            if not placed:
                break
            k += 1
        report[name] = {'copied_section_axial_px': [round(float(a), 2), round(float(b), 2)], 'step_px': list(T),
                        'sideways_drift_per_step_px': round(float(abs(np.array(T, float) @ n)), 4),
                        'copies': k - 1, 'original_cells_replaced': int(beyond.sum())}
    return L, S, report


def focus_center(labels, fam, blend):
    """Composition center in logical px: the wordmark's horizontal center; vertically
    `blend` of the way from the full artwork's center to the wordmark's center."""
    ty, tx = np.nonzero(fam[labels] == 'text')
    ay, ax = np.nonzero(labels != 0)
    text_c = ((tx.min() + tx.max() + 1) / 2, (ty.min() + ty.max() + 1) / 2)
    art_cy = (ay.min() + ay.max() + 1) / 2
    return text_c[0], art_cy + blend * (text_c[1] - art_cy), text_c
