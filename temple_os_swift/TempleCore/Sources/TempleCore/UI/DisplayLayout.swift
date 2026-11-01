import Foundation

// Swift-first: not yet in the Kotlin core (docs/foldable/IPHONE_DUO_ADAPTATION.md). With no reserved
// regions and no corner adaptation (every caller of Shell.resize), the shell lays out exactly as the
// Kotlin core does, so the shared ShellUi screenshots stay identical.

/**
 * The screen area the shell lays out into, as the platform view measured it in logical px: its size,
 * the system insets, the keyboard, and the reserved regions of a foldable or cut-out display.
 * Platform adapters build one per layout pass (iOS: TempleView) and hand it to [Shell.apply].
 */
public struct DisplayGeometry: Equatable, CustomStringConvertible {
    public var width: Int, height: Int
    /** Safe-area insets (status bar, home indicator, a status-bar column at a side). */
    public var top: Int, bottom: Int, left: Int, right: Int
    /** Height of the device keyboard above the bottom edge (0 when hidden). */
    public var keyboard: Int
    /** pt (or dp) per logical px. */
    public var dpPerPx: Double
    /**
     * Left and right insets for the top bar row when it reaches into the screen's rounded top corners
     * (no status bar above it): the platform's corner-adapted safe area. Never less than [left]/[right].
     */
    public var barLeft: Int, barRight: Int
    /** Active division regions (a partly folded hinge), margins included. */
    public var divisions: [Rect]
    /** Active occlusion regions (camera housing, a status-bar block) inside the view. */
    public var occlusions: [Rect]

    public init(width: Int, height: Int, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0, keyboard: Int = 0,
                dpPerPx: Double = 1, barLeft: Int = 0, barRight: Int = 0, divisions: [Rect] = [], occlusions: [Rect] = []) {
        self.width = width; self.height = height; self.top = top; self.bottom = bottom; self.left = left; self.right = right
        self.keyboard = keyboard; self.dpPerPx = dpPerPx; self.barLeft = barLeft; self.barRight = barRight
        self.divisions = divisions; self.occlusions = occlusions
    }

    public var description: String {
        func r(_ a: [Rect]) -> String { a.map { "\($0.x),\($0.y),\($0.w),\($0.h)" }.joined(separator: "|") }
        return "\(width)x\(height) t\(top) b\(bottom) l\(left) r\(right) kb\(keyboard) bar\(barLeft)/\(barRight) div[\(r(divisions))] occ[\(r(occlusions))]"
    }
}

/**
 * The layout policy for every screen shape (docs/foldable/IPHONE_DUO_ADAPTATION.md): pure functions of
 * the geometry, so tests exercise any phone, foldable posture or multitasking window without a device.
 * Decisions follow the space available, never a device model or an orientation label.
 */
public enum DisplayLayout {
    /** The smallest surface the shell lays out (logical px). */
    public static let MIN_W = 320, MIN_H = 240
    /**
     * AUTO keeps one logical px at one pt (the phone density the menus, keyboard and fonts were sized for)
     * until the shorter side would exceed this many logical px; larger windows magnify by whole factors.
     * Phones (shorter side under 480 pt) get exactly the sizes they had; an unfolded foldable shows more
     * TempleOS (the 640 px wide original fits) instead of the phone layout blown up.
     */
    public static let MAX_AUTO_SHORT = 720
    /**
     * A usable area at least this big in both directions holds overlapping TempleOS windows (a default
     * window is 2/3 x 3/4 of it) even when it is taller than wide; smaller tall areas show one window
     * at a time (the deck).
     */
    public static let WINDOWED_MIN = 600
    /** A fold region narrower or shorter than this (logical px) is not used to place things. */
    public static let MIN_REGION = 120

    /**
     * Device pixels per logical px. [chosen] > 0 is the user's Display scale setting; else AUTO.
     * The surface never gets smaller than MIN_W x MIN_H (very small multitasking windows).
     */
    public static func scale(pxW: Int, pxH: Int, displayScale: Double, chosen: Int = 0) -> Int {
        let w = max(1, pxW), h = max(1, pxH)
        var s: Int
        if chosen > 0 { s = chosen } else {
            s = max(1, Int((displayScale.isFinite && displayScale > 0 ? displayScale : 1).rounded()))
            while min(w, h) / s > MAX_AUTO_SHORT { s += 1 }
        }
        while s > 1 && (w / s < MIN_W || h / s < MIN_H) { s -= 1 }
        return s
    }

    /**
     * True when the desktop shows overlapping windows (the original TempleOS desktop), false for the
     * one-window deck: wider than tall, or big enough in both directions ([WINDOWED_MIN]).
     */
    public static func windowed(_ w: Int, _ h: Int, usableW: Int, usableH: Int) -> Bool {
        w > h || (usableW >= WINDOWED_MIN && usableH >= WINDOWED_MIN)
    }

    /**
     * [g] with sizes the layout can always honour: at least 160 x 160, insets and keyboard that leave at
     * least 96 px across and 64 px down, a finite positive pt-per-px, regions clipped to the screen.
     */
    public static func sanitized(_ g: DisplayGeometry) -> DisplayGeometry {
        var o = g
        o.width = max(g.width, 160); o.height = max(g.height, 160)
        func fit(_ a: Int, _ b: Int, _ room: Int) -> (Int, Int) {
            let a = max(0, a), b = max(0, b)
            if a + b <= room { return (a, b) }
            let s = Double(room) / Double(a + b)
            return (Int(Double(a) * s), Int(Double(b) * s))
        }
        (o.left, o.right) = fit(g.left, g.right, o.width - 96)
        (o.top, o.bottom) = fit(g.top, g.bottom, o.height - 64)
        o.keyboard = min(max(0, g.keyboard), o.height - o.top - 64)
        o.barLeft = min(max(0, g.barLeft), (o.width - 96) / 2); o.barRight = min(max(0, g.barRight), (o.width - 96) / 2)
        if !(g.dpPerPx.isFinite && g.dpPerPx > 0) { o.dpPerPx = 1 }
        let screen = Rect(0, 0, o.width, o.height)
        o.divisions = g.divisions.map { $0.intersect(screen) }.filter { $0.w > 0 && $0.h > 0 }
        o.occlusions = g.occlusions.map { $0.intersect(screen) }.filter { $0.w > 0 && $0.h > 0 }
        return o
    }

    /** The part of [d] that runs across [r] from one side to the other (a fold), or nil. */
    public static func crossing(_ d: Rect, _ r: Rect) -> Rect? {
        let x0 = max(d.x, r.x), x1 = min(d.right, r.right), y0 = max(d.y, r.y), y1 = min(d.bottom, r.bottom)
        if x1 <= x0 || y1 <= y0 { return nil }
        let vertical = d.y <= r.y && d.bottom >= r.bottom
        let horizontal = d.x <= r.x && d.right >= r.right
        if !vertical && !horizontal { return nil }
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /**
     * True when [d] (crossing [r]) splits it into left and right parts: it runs from [r]'s top to its bottom
     * without also covering its whole width (a fold clipped to a short keyboard row is still vertical).
     */
    public static func isVertical(_ d: Rect, in r: Rect) -> Bool {
        let fullHeight = d.y <= r.y && d.bottom >= r.bottom, fullWidth = d.x <= r.x && d.right >= r.right
        if fullHeight != fullWidth { return fullHeight }
        return d.h >= d.w
    }

    /**
     * [r] split by the divisions that run across it: left/right parts for a vertical fold (book), top/bottom
     * parts for a horizontal one (tabletop). Parts smaller than [MIN_REGION] are dropped; without a usable
     * split the result is [r] alone.
     */
    public static func regions(_ r: Rect, _ divisions: [Rect]) -> [Rect] {
        var parts = [r]
        for d in divisions {
            var next: [Rect] = []
            for p in parts {
                guard let c = crossing(d, p) else { next.append(p); continue }
                if isVertical(c, in: p) {
                    next.append(Rect(p.x, p.y, c.x - p.x, p.h)); next.append(Rect(c.right, p.y, p.right - c.right, p.h))
                } else {
                    next.append(Rect(p.x, p.y, p.w, c.y - p.y)); next.append(Rect(p.x, c.bottom, p.w, p.bottom - c.bottom))
                }
            }
            parts = next
        }
        let usable = parts.filter { $0.w >= MIN_REGION && $0.h >= MIN_REGION }
        return usable.count >= 2 ? usable : [r]
    }

    /** The region holding ([x], [y]), else the one nearest to it. */
    public static func region(at x: Int, _ y: Int, _ regions: [Rect]) -> Rect {
        if let r = regions.first(where: { $0.contains(x, y) }) { return r }
        func dist(_ r: Rect) -> Int {
            let dx = x < r.x ? r.x - x : x >= r.right ? x - r.right + 1 : 0
            let dy = y < r.y ? r.y - y : y >= r.bottom ? y - r.bottom + 1 : 0
            return dx + dy
        }
        return regions.min { dist($0) < dist($1) } ?? Rect(x, y, 0, 0)
    }

    /**
     * The horizontal span [x0, x1) of a row [y0, y1) that no occlusion covers: an occlusion that reaches
     * in from the left (its center in the left half) moves x0 past it, one from the right moves x1 before it.
     */
    public static func rowSpan(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int, _ occlusions: [Rect]) -> (Int, Int) {
        var a = x0, b = x1
        let mid = (x0 + x1) / 2
        for o in occlusions where o.y < y1 && o.bottom > y0 && o.right > a && o.x < b {
            if o.x + o.w / 2 < mid { a = max(a, o.right) } else { b = min(b, o.x) }
        }
        return b - a >= 16 ? (a, b) : (x0, x1)
    }

    /**
     * Columns for a row of keys with relative widths [weights] across [r], skipping the part of [r] that
     * [gap] covers (a vertical fold): the row breaks at the key boundary nearest the fold, keys before it
     * fill the left part and the rest the right part, so no key lies on the hinge. Returns [x0, x1) per key.
     */
    public static func keyColumns(_ weights: [Int], _ r: Rect, gap: Rect?) -> [(Int, Int)] {
        let total = max(1, weights.reduce(0, +))
        func spread(_ ws: [Int], _ x0: Int, _ w: Int) -> [(Int, Int)] {
            let t = max(1, ws.reduce(0, +))
            var acc = 0
            return ws.map { k in let a = x0 + acc * w / t; acc += k; return (a, x0 + acc * w / t) }
        }
        guard let g = gap, g.x > r.x, g.right < r.right, weights.count >= 2 else { return spread(weights, r.x, r.w) }
        // the fold's center as a share of the row; break at the boundary nearest to it (not before the first key)
        let at = Double(g.x + g.w / 2 - r.x) / Double(r.w) * Double(total)
        var best = 1, acc = 0, bestD = Double.infinity
        for i in 0..<(weights.count - 1) {
            acc += weights[i]
            let d = abs(Double(acc) - at)
            if d < bestD { bestD = d; best = i + 1 }
        }
        let leftW = g.x - r.x, rightX = g.right
        return spread(Array(weights[0..<best]), r.x, leftW) + spread(Array(weights[best...]), rightX, r.right - rightX)
    }
}
