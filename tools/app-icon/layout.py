"""Icon geometry: launcher masks, placement of the pixel art, clearance measurement.

Coordinates are in "icon units": the visible icon is the unit square [0, 1] x [0, 1]
(y down). For iOS that is the whole 1024 px canvas. For an Android adaptive icon it is
the 72 dp viewport in the middle of the 108 dp layer, so the layer spans [-0.25, 1.25].

Clearance is measured from every corner of every non-background logical pixel to the
mask outline (all masks here are convex, so a square is inside when its corners are and
its distance to the outline is attained at a corner). A bounding box would miss the
diagonal sword: its tip is in a corner region that the rounded masks cut away.
"""
import math
import numpy as np

# ------------------------------------------------------------------- mask outlines

def _cubic(p0, p1, p2, p3, n=24):
    t = np.linspace(0, 1, n)[:, None]
    return ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3


def ios_continuous_rect(r):
    """UIKit continuous-corner rounded rectangle (the iOS app icon outline), unit square.

    Corner geometry: the published reverse-engineering of
    UIBezierPath(roundedRect:cornerRadius:) since iOS 7: three cubic segments per corner
    spanning 1.52866483 r along each edge.
    """
    k = [1.52866483, 1.08849323, 0.86840689, 0.63149399, 0.07491100, 0.37282392, 0.16905899]
    a, b, c, d, e, f, g = (v * r for v in k)
    P = lambda x, y: np.array((1 - x, y))                 # offsets from the top-right corner (1, 0)
    tr = np.vstack([_cubic(P(a, 0), P(b, 0), P(c, 0), P(d, e)),
                    _cubic(P(d, e), P(f, g), P(g, f), P(e, d)),
                    _cubic(P(e, d), P(0, c), P(0, b), P(0, a))])
    x, y = tr[:, 0], tr[:, 1]                              # the outline is symmetric in both axes
    pts = np.vstack([tr, np.column_stack([1 - x, y]), np.column_stack([x, 1 - y]), np.column_stack([1 - x, 1 - y])])
    return _clockwise_hull(pts)


def circle(n=720):
    t = np.linspace(0, 2 * math.pi, n, endpoint=False)
    return np.column_stack([0.5 + 0.5 * np.cos(t), 0.5 + 0.5 * np.sin(t)])


def rounded_rect(r, n=60):
    pts = []
    for cx, cy, a0 in ((1 - r, r, -90), (1 - r, 1 - r, 0), (r, 1 - r, 90), (r, r, 180)):
        t = np.radians(np.linspace(a0, a0 + 90, n))
        pts.append(np.column_stack([cx + r * np.cos(t), cy + r * np.sin(t)]))
    return np.vstack(pts)


def aosp_squircle():
    """AOSP config_icon_mask squircle: M50,0 C10,0 0,10 0,50 0,90 10,100 50,100 90,100 100,90 100,50 100,10 90,0 50,0 Z."""
    P = lambda x, y: np.array((x / 100, y / 100))
    segs = [(P(50, 0), P(10, 0), P(0, 10), P(0, 50)), (P(0, 50), P(0, 90), P(10, 100), P(50, 100)),
            (P(50, 100), P(90, 100), P(100, 90), P(100, 50)), (P(100, 50), P(100, 10), P(90, 0), P(50, 0))]
    return np.vstack([_cubic(*s, n=90)[:-1] for s in segs])


def teardrop():
    """AOSP teardrop: three quarter-circle corners of radius 50 and one of radius 15 (bottom right)."""
    pts = []
    for cx, cy, r, a0 in ((50, 50, 50, 180), (50, 50, 50, 270), (85, 85, 15, 0), (50, 50, 50, 90)):
        t = np.radians(np.linspace(a0, a0 + 90, 90))
        pts.append(np.column_stack([cx + r * np.cos(t), cy + r * np.sin(t)]))
    q = np.vstack(pts)
    q[(q[:, 0] > 50) & (q[:, 1] > 50) & ((q[:, 0] - 85) ** 2 + (q[:, 1] - 85) ** 2 > 15.01 ** 2)] = np.nan
    q = q[~np.isnan(q).any(1)]
    q = np.vstack([q, [[100, 50], [100, 85], [85, 100], [50, 100]]])
    return _clockwise_hull(q / 100)


def square():
    return np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float)


def _clockwise_hull(p):
    """Convex hull (monotone chain), clockwise in y-down coordinates."""
    p = np.unique(np.round(p, 9), axis=0)
    p = p[np.lexsort((p[:, 1], p[:, 0]))]

    def half(points):
        h = []
        for q in points:
            while len(h) >= 2 and np.cross(h[-1] - h[-2], q - h[-2]) <= 0:
                h.pop()
            h.append(q)
        return h
    lower, upper = half(p), half(p[::-1])
    return np.array(lower[:-1] + upper[:-1])


IOS_MASKS = {
    'ios-rounded-rect': ios_continuous_rect(0.2237),
    'ios-rounded-rect-conservative': ios_continuous_rect(0.25),
}
ANDROID_MASKS = {
    'android-circle': circle(),
    'android-squircle': aosp_squircle(),
    'android-rounded-square': rounded_rect(0.24),
    'android-rounded-square-small': rounded_rect(0.08),
    'android-teardrop': teardrop(),
    'android-square': square(),
}
# Google Play rounds the 512 px listing icon with a 20% corner radius
PLAY_MASK = rounded_rect(0.20)
# Android guarantees only this circle (66 dp of the 72 dp viewport) for every launcher shape
ANDROID_SAFE_ZONE = circle() * (66 / 72) + (1 - 66 / 72) / 2

# ---------------------------------------------------------------------- clearance

def art_corners(labels, bg=0):
    """Corners (x, y) in logical-pixel units of all non-background logical pixels, deduplicated."""
    ys, xs = np.nonzero(labels != bg)
    c = np.concatenate([np.column_stack([xs + dx, ys + dy]) for dx in (0, 1) for dy in (0, 1)])
    return np.unique(c, axis=0).astype(float)


def clearance(points, poly):
    """Signed distance of each point to a convex polygon outline (positive inside)."""
    a = poly
    b = np.roll(poly, -1, axis=0)
    e = b - a
    # orientation: positive area -> clockwise in y-down
    area = 0.5 * np.sum(a[:, 0] * b[:, 1] - b[:, 0] * a[:, 1])
    sign = 1 if area > 0 else -1
    out = np.empty(len(points))
    for s in range(0, len(points), 4096):
        p = points[s:s + 4096][:, None, :]
        ap = p - a[None]
        t = np.clip((ap * e[None]).sum(-1) / (e * e).sum(-1)[None], 0, 1)
        d = np.sqrt(((ap - t[..., None] * e[None]) ** 2).sum(-1)).min(1)
        cross = e[None, :, 0] * ap[..., 1] - e[None, :, 1] * ap[..., 0]
        inside = (sign * cross >= -1e-12).all(1)
        out[s:s + 4096] = np.where(inside, d, -d)
    return out


def place(corners, cell, origin):
    """Logical-pixel corners -> icon units, for a cell size and origin (both in icon units)."""
    return corners * cell + np.asarray(origin)


def report(corners, cell, origin, masks):
    """Minimum clearance (icon units) per mask, and where it occurs."""
    pts = place(corners, cell, origin)
    out = {}
    for name, poly in masks.items():
        c = clearance(pts, poly)
        k = int(np.argmin(c))
        out[name] = {'min_clearance': float(c[k]), 'at_logical': [float(v) for v in corners[k]]}
    return out


def enclosing_circle(points):
    """Smallest enclosing circle (Welzl, iterative) of 2-D points -> (cx, cy, r)."""
    pts = [tuple(p) for p in np.unique(points, axis=0)]
    # only the convex hull matters
    hull = _clockwise_hull(np.array(pts))
    P = [tuple(p) for p in hull]

    def circ2(a, b):
        cx, cy = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        return cx, cy, math.dist(a, (cx, cy))

    def circ3(a, b, c):
        ax, ay = a; bx, by = b; cx, cy = c
        d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        if abs(d) < 1e-12:
            return None
        ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
        uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
        return ux, uy, math.dist(a, (ux, uy))

    def inside(c, p):
        return c is not None and math.dist((c[0], c[1]), p) <= c[2] + 1e-9

    c = None
    for i, p in enumerate(P):
        if c is None or not inside(c, p):
            c = (p[0], p[1], 0.0)
            for j, q in enumerate(P[:i]):
                if not inside(c, q):
                    c = circ2(p, q)
                    for r in P[:j]:
                        if not inside(c, r):
                            c = circ3(p, q, r) or c
    return c
