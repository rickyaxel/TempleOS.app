import Foundation

// Port of ui/Surface.kt.

/** Rectangle in logical pixels. */
public struct Rect: Equatable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var right: Int { x + w }
    public var bottom: Int { y + h }
    public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && py >= y && px < x + w && py < y + h }
    public func inset(_ d: Int) -> Rect { Rect(x + d, y + d, max(0, w - 2 * d), max(0, h - 2 * d)) }

    public func intersect(_ o: Rect) -> Rect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(right, o.right), y1 = min(bottom, o.bottom)
        return Rect(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }
}

/**
 * The shell's indexed (16-color) framebuffer in logical pixels. One font
 * pixel is one logical pixel; platforms scale by an integer factor with
 * nearest-neighbour sampling.
 */
public final class Surface {
    /** Keep action labels at their natural width; move actions/path/status to another row when needed. */
    public func toolbarLayout(_ labels: [String], _ r: Rect, _ rowH: Int, _ trailingMin: Int) -> (buttons: [Rect], trailing: Rect, height: Int) {
        var x = r.x + 2, y = r.y
        var buttons: [Rect] = []
        for label in labels {
            let w = min(max(8, r.w - 4), measureUi(label) + 8)
            if x > r.x + 2 && x + w > r.right - 2 { x = r.x + 2; y += rowH }
            buttons.append(Rect(x, y + 1, w, rowH - 2)); x += w + 4
        }
        if r.right - x < trailingMin { x = r.x + 2; y += rowH }
        return (buttons, Rect(x, y, max(0, r.right - x - 2), rowH), y - r.y + rowH)
    }

    private let font: [UInt8]
    public private(set) var width: Int
    public private(set) var height: Int
    /** width * height indexed pixels (reallocated by [resize]). */
    public private(set) var px: UnsafeMutablePointer<UInt8>
    /** Incremented when the content changes (platform uploads on change). */
    public private(set) var version: Int64 = 0

    private var clip: Rect

    public init(_ width: Int, _ height: Int, _ font: [UInt8]) {
        self.width = width; self.height = height; self.font = font
        px = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, width * height))
        px.initialize(repeating: 0, count: max(1, width * height))
        clip = Rect(0, 0, width, height)
    }

    deinit { px.deallocate() }

    public func resize(_ w: Int, _ h: Int) {
        if w == width && h == height { return }
        width = w; height = h
        px.deallocate()
        px = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, w * h))
        px.initialize(repeating: 0, count: max(1, w * h))
        clip = Rect(0, 0, w, h)
    }

    public func touch() { version += 1 }

    // ------------------------------------------------------------ text the TempleOS font cannot show

    /**
     * A string with characters outside the TempleOS font (CJK, Arabic, Devanagari, Cyrillic,
     * most non-Western-European Latin…). The platform draws it with its own text engine at
     * device resolution (shaping, bidi), inside [clip] and outside every [Occluder] with a
     * higher [z]. [x], [y], [w] are logical px; [y] is the top of the 8 px TempleOS text row.
     */
    public final class TextRun {
        public let x: Int, y: Int, w: Int, text: String, fg: Int, rtl: Bool, clip: Rect, z: Int
        /** Text magnification, as for TempleOS glyphs ([MenuMetrics.textScale]): 10*scale px on an 8*scale px row. */
        public let scale: Int
        public init(_ x: Int, _ y: Int, _ w: Int, _ text: String, _ fg: Int, _ rtl: Bool, _ clip: Rect, _ z: Int, _ scale: Int = 1) {
            self.x = x; self.y = y; self.w = w; self.text = text; self.fg = fg; self.rtl = rtl; self.clip = clip; self.z = z; self.scale = scale
        }
    }

    /** Something drawn opaquely above earlier text runs (a window, menu, dialog, keyboard…). */
    public final class Occluder {
        public let rect: Rect, z: Int
        public init(_ rect: Rect, _ z: Int) { self.rect = rect; self.z = z }
    }

    /**
     * The vertical span (logical px, top to bottom) a text run's ink may use: its clip (the row's box, 2*scale above
     * and below the 8*scale row, cut by its container), less any part covered by something drawn above it that
     * overlaps the run horizontally: a window title's box ends where the window's menu bar starts. The platforms keep the run's
     * ink inside it (moved, or the font made just small enough) so tall scripts are not cut. Port of Surface.kt.
     */
    public static func runInkBox(_ r: TextRun, _ occluders: [Occluder]) -> (Int, Int) {
        var top = r.clip.y, bottom = r.clip.bottom
        let mid = r.y + 4 * r.scale
        for o in occluders {
            if o.z <= r.z || o.rect.right <= r.clip.x || o.rect.x >= r.clip.right { continue }
            if o.rect.y >= mid { bottom = min(bottom, o.rect.y) } else if o.rect.bottom <= mid { top = max(top, o.rect.bottom) }
        }
        return (top, max(bottom, top + 1))
    }

    public var runs: [TextRun] = []
    public var occluders: [Occluder] = []
    private var z = 0

    /** Logical-px width of a string drawn by the platform (set by the shell from its env). */
    public var measureNative: (String) -> Int = { $0.scLen * 8 }

    /** Clears runs and occluders at the start of a full render. */
    public func beginFrame() { runs.removeAll(keepingCapacity: true); occluders.removeAll(keepingCapacity: true); z = 0 }

    /** Starts a new stacking layer; [r] hides the text runs of every earlier layer. */
    public func layer(_ r: Rect?) { z += 1; if let r = r { occluders.append(Occluder(r, z)) } }

    /** Width of localized UI text in logical px (8 per char in the TempleOS font), magnified by [scale]. */
    public func measureUi(_ s: String, _ scale: Int = 1) -> Int { Cp437.representable(s) ? s.scLen * 8 * scale : measureNative(s) * scale }

    /**
     * Draws localized UI text: with the TempleOS font when every character exists in it, else
     * as a [TextRun]. Text wider than [maxW] is cut. With [alignEnd] (right-to-left languages)
     * the text ends at x + maxW. [scale] magnifies each font pixel to scale x scale logical px
     * (menus, MenuMetrics); the row is then 8*scale px high. Returns the x after the text.
     */
    @discardableResult
    public func uiText(_ x: Int, _ y: Int, _ s: String, _ fg: Int, _ maxW: Int = Int.max, _ bg: Int = -1, alignEnd: Bool = false, scale: Int = 1) -> Int {
        if s.isEmpty { return x }
        let cw = 8 * scale
        if Cp437.representable(s) {
            let enc = Cp437.encode(s).scArr
            let n = maxW == Int.max ? enc.count : min(enc.count, max(0, maxW / cw))
            let tx = alignEnd && maxW != Int.max ? x + maxW - n * cw : x
            for i in 0..<n { glyph(tx + i * cw, y, Int(enc[i].value), fg, bg, scale: scale) }
            return tx + n * cw
        }
        let w = min(measureNative(s) * scale, maxW)
        let limit = maxW == Int.max ? w : maxW
        if bg >= 0 { fillRect(x, y, limit, cw, bg) }
        let c = clip
        let box = Rect(x, y - 2 * scale, limit, 12 * scale)
        let x0 = max(c.x, box.x), y0 = max(c.y, box.y)
        let x1 = min(c.right, box.right), y1 = min(c.bottom, box.bottom)
        if x1 > x0 && y1 > y0 { runs.append(TextRun(x, y, limit, s, fg, alignEnd, Rect(x0, y0, x1 - x0, y1 - y0), z, scale)) }
        return x + w
    }

    /** Splits [s] into lines no wider than [maxW] at [scale]: at spaces, or anywhere for scripts without them. */
    public func wrapUi(_ s: String, _ maxW: Int, _ scale: Int = 1) -> [String] {
        var out: [String] = []
        for para in s.scSplit("\n") {
            var line = ""
            for word in para.scSplit(" ") {
                let cand = line.isEmpty ? word : "\(line) \(word)"
                if measureUi(cand, scale) <= maxW { line = cand; continue }
                if !line.isEmpty { out.append(line); line = "" }
                // A long word or an unspaced script: keep each extended grapheme cluster intact.
                var rest = word
                while measureUi(rest, scale) > maxW && rest.count > 1 {
                    var end = rest.index(before: rest.endIndex)
                    let first = rest.index(after: rest.startIndex)
                    while end > first && measureUi(String(rest[..<end]), scale) > maxW { end = rest.index(before: end) }
                    out.append(String(rest[..<end])); rest = String(rest[end...])
                }
                line = rest
            }
            out.append(line)
        }
        return out
    }

    public func setClip(_ r: Rect?) {
        if let r = r {
            let x0 = max(0, r.x), y0 = max(0, r.y)
            let x1 = min(width, r.right), y1 = min(height, r.bottom)
            clip = Rect(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
        } else {
            clip = Rect(0, 0, width, height)
        }
    }

    public func withClip(_ r: Rect, _ block: () throws -> Void) rethrows {
        let saved = getClip()
        setClip(r.intersect(saved))
        defer { setClip(saved) }
        try block()
    }

    public func getClip() -> Rect { clip }

    public func plot(_ x: Int, _ y: Int, _ c: Int) {
        if x < clip.x || y < clip.y || x >= clip.right || y >= clip.bottom { return }
        px[y * width + x] = UInt8(truncatingIfNeeded: c)
    }

    public func fill(_ r: Rect, _ c: Int) { fillRect(r.x, r.y, r.w, r.h, c) }

    public func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Int) {
        let x0 = max(x, clip.x), y0 = max(y, clip.y)
        let x1 = min(x + w, clip.right), y1 = min(y + h, clip.bottom)
        if x0 >= x1 || y0 >= y1 { return }
        let b = UInt8(truncatingIfNeeded: c)
        for yy in y0..<y1 { (px + yy * width + x0).update(repeating: b, count: x1 - x0) }
    }

    public func hline(_ x0: Int, _ x1: Int, _ y: Int, _ c: Int) { fillRect(min(x0, x1), y, abs(x1 - x0) + 1, 1, c) }
    public func vline(_ x: Int, _ y0: Int, _ y1: Int, _ c: Int) { fillRect(x, min(y0, y1), 1, abs(y1 - y0) + 1, c) }

    public func frame(_ r: Rect, _ c: Int) {
        hline(r.x, r.right - 1, r.y, c); hline(r.x, r.right - 1, r.bottom - 1, c)
        vline(r.x, r.y, r.bottom - 1, c); vline(r.right - 1, r.y, r.bottom - 1, c)
    }

    public func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Int) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            plot(x, y, c)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /**
     * Draws one 8x8 TempleOS glyph; bg < 0 is transparent. With [scale] > 1 every font pixel is a
     * scale x scale block of logical pixels (integer magnification: as crisp as the font itself).
     */
    public func glyph(_ x: Int, _ y: Int, _ ch: Int, _ fg: Int, _ bg: Int = -1, underline: Bool = false, scale: Int = 1) {
        if scale > 1 { glyphScaled(x, y, ch, fg, bg, underline, scale); return }
        if x >= clip.right || y >= clip.bottom || x + 8 <= clip.x || y + 8 <= clip.y { return }
        let code = ch & 0xFF
        let fb: [UInt8]? = (code >= 0x10 && code <= 0x1B && isBlank(code)) ? UI_GLYPHS[code - 0x10] : nil
        let base = code * 8
        let f = UInt8(truncatingIfNeeded: fg), b = UInt8(truncatingIfNeeded: bg)
        for r in 0..<8 {
            let yy = y + r
            if yy < clip.y || yy >= clip.bottom { continue }
            var bits = fb != nil ? Int(fb![r]) : Int(font[base + r])
            if underline && r == 7 { bits = 0xFF }
            let row = yy * width
            for c in 0..<8 {
                let xx = x + c
                if xx < clip.x || xx >= clip.right { continue }
                if (bits >> c) & 1 != 0 { px[row + xx] = f } else if bg >= 0 { px[row + xx] = b }
            }
        }
    }

    private func glyphScaled(_ x: Int, _ y: Int, _ ch: Int, _ fg: Int, _ bg: Int, _ underline: Bool, _ k: Int) {
        if x >= clip.right || y >= clip.bottom || x + 8 * k <= clip.x || y + 8 * k <= clip.y { return }
        let code = ch & 0xFF
        let fb: [UInt8]? = (code >= 0x10 && code <= 0x1B && isBlank(code)) ? UI_GLYPHS[code - 0x10] : nil
        let base = code * 8
        for r in 0..<8 {
            var bits = fb != nil ? Int(fb![r]) : Int(font[base + r])
            if underline && r == 7 { bits = 0xFF }
            for c in 0..<8 {
                if (bits >> c) & 1 != 0 { fillRect(x + c * k, y + r * k, k, k, fg) } else if bg >= 0 { fillRect(x + c * k, y + r * k, k, k, bg) }
            }
        }
    }

    private func isBlank(_ code: Int) -> Bool {
        for r in 0..<8 where font[code * 8 + r] != 0 { return false }
        return true
    }

    /** Draws text with 8x8 cells (magnified by [scale]). Returns the x after the last char. */
    @discardableResult
    public func text(_ x: Int, _ y: Int, _ s: String, _ fg: Int, _ bg: Int = -1, scale: Int = 1) -> Int {
        var cx = x
        for ch in s.unicodeScalars { glyph(cx, y, Int(ch.value) & 0xFF, fg, bg, scale: scale); cx += 8 * scale }
        return cx
    }

    /** Draws a TempleOS cell (char | fg<<8 | bg<<12 | flags) at pixel (x,y). */
    public func cell(_ x: Int, _ y: Int, _ cell: Int) {
        var fg = (cell >> 8) & 15
        var bg = (cell >> 12) & 15
        if cell & 0x20000000 != 0 { let t = fg; fg = bg; bg = t }
        glyph(x, y, cell & 0xFF, fg, bg, underline: cell & 0x80000000 != 0)
    }

    /**
     * TempleOS window border using the font's box-drawing glyphs 2..13
     * (double lines when [solid]); the title is drawn into the top edge.
     */
    public func border(_ r: Rect, _ fg: Int, _ bg: Int, _ solid: Bool, _ title: String? = nil) {
        let s = solid ? 1 : 0
        let cols = r.w / 8, rows = r.h / 8
        if cols < 2 || rows < 2 { return }
        for i in 1..<(cols - 1) {
            glyph(r.x + i * 8, r.y, 2 + s, fg, bg)
            glyph(r.x + i * 8, r.y + (rows - 1) * 8, 2 + s, fg, bg)
        }
        for j in 1..<(rows - 1) {
            glyph(r.x, r.y + j * 8, 4 + s, fg, bg)
            glyph(r.x + (cols - 1) * 8, r.y + j * 8, 4 + s, fg, bg)
        }
        glyph(r.x, r.y, 6 + s, fg, bg)
        glyph(r.x + (cols - 1) * 8, r.y, 8 + s, fg, bg)
        glyph(r.x, r.y + (rows - 1) * 8, 10 + s, fg, bg)
        glyph(r.x + (cols - 1) * 8, r.y + (rows - 1) * 8, 12 + s, fg, bg)
        if let title = title, cols > 4 {
            // the title lives in the 8-row border band: what is drawn under it (a window's chrome bar) is not an
            // occluder, so a platform-drawn title is fitted to the band (runInkBox), as the TempleOS glyphs are
            withClip(Rect(r.x, r.y, r.w, 8)) { _ = uiText(r.x + 16, r.y, title, fg, (cols - 4) * 8, bg) }
        }
    }

    /** Copies an indexed image (e.g. a program frame) scaled by nearest neighbour into [dst]. */
    /** Draws [part] of the [sw]x[sh] indexed image [src] scaled into [dst] (nearest neighbour). */
    public func blitScaled(_ src: UnsafePointer<UInt8>, _ sw: Int, _ sh: Int, _ dst: Rect, _ part: Rect? = nil) {
        if dst.w <= 0 || dst.h <= 0 { return }
        let pr = part ?? Rect(0, 0, sw, sh)
        let x0 = max(dst.x, clip.x), y0 = max(dst.y, clip.y)
        let x1 = min(dst.right, clip.right), y1 = min(dst.bottom, clip.bottom)
        if x0 >= x1 { return }
        for y in stride(from: y0, to: y1, by: 1) {
            let sy = pr.y + (y - dst.y) * pr.h / dst.h
            let srow = sy * sw + pr.x
            let drow = y * width
            for x in x0..<x1 { px[drow + x] = src[srow + (x - dst.x) * pr.w / dst.w] }
        }
    }

    public func blitScaled(_ src: [UInt8], _ sw: Int, _ sh: Int, _ dst: Rect, _ part: Rect? = nil) {
        src.withUnsafeBufferPointer { b in
            guard let p = b.baseAddress else { return }
            blitScaled(p, sw, sh, dst, part)
        }
    }
}

/**
 * Shell-only glyphs for codes 0x10..0x1B, which are blank in the TempleOS font
 * (TempleOS uses them as control codes). Bit 0 is the leftmost pixel.
 */
private let UI_GLYPHS: [[UInt8]?] = {
    func b(_ r: Int...) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: $0 < r.count ? r[$0] : 0) } }
    var g = [[UInt8]?](repeating: nil, count: 12)
    g[0x00] = b(0x02, 0x06, 0x0E, 0x1E, 0x0E, 0x06, 0x02)      // 0x10 right triangle
    g[0x01] = b(0x40, 0x60, 0x70, 0x78, 0x70, 0x60, 0x40)      // 0x11 left triangle
    g[0x08] = b(0x18, 0x3C, 0x7E, 0x18, 0x18, 0x18, 0x18)      // 0x18 up arrow
    g[0x09] = b(0x18, 0x18, 0x18, 0x18, 0x7E, 0x3C, 0x18)      // 0x19 down arrow
    g[0x0A] = b(0x00, 0x20, 0x60, 0xFF, 0x60, 0x20)            // 0x1A right arrow
    g[0x0B] = b(0x00, 0x04, 0x06, 0xFF, 0x06, 0x04)            // 0x1B left arrow
    return g
}()
