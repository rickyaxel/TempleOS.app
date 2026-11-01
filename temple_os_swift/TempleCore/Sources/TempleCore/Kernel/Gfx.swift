import Foundation

/**
 * Native graphics layer of a kernel: the per-pixel primitive (GrPlot0, a port of
 * TempleOS Adam/Gr/GrBitMap.HC), the text layer, and screen composition.
 * Everything above GrPlot0 is the original TempleOS HolyC graphics library.
 * Port of kernel/Gfx.kt.
 */
public final class Gfx {
    private unowned let k: Kernel
    /** Kotlin `k.mem` (the VM arena is created once and never replaced). */
    private let m: Arena
    private var o: Offsets { k.o }

    // CDC member offsets
    private let oWidth: Int
    private let oWI: Int
    private let oHeight: Int
    private let oFlags: Int
    private let oColor: Int
    private let oBk: Int
    private let oBody: Int
    private let oDb: Int
    private let oDbZ: Int
    private let oCurX: Int
    private let oCurY: Int
    private let oNearest: Int
    private let oMinX: Int
    private let oMaxX: Int
    private let oMinY: Int
    private let oMaxY: Int
    private let oCollision: Int
    private let oDither: Int
    private let oSig: Int

    private let grDcOff: Int
    private let grDc2Off: Int
    private let grDc1Off: Int
    private let grTextOff: Int

    public private(set) var grDc: Int64 = 0
    public private(set) var grDc2: Int64 = 0
    public private(set) var textBase = 0
    public private(set) var fontAddr = 0

    public static let DCF_LOCATE_NEAREST: Int64 = 0x800
    public static let DCF_DONT_DRAW: Int64 = 0x1000
    public static let DCF_RECORD_EXTENTS: Int64 = 0x10000
    public static let DCF_SCRN_BITMAP: Int64 = 0x4000
    public static let DCS_SIG = chCode("DvCS")
    public static let ATTRF_BLINK: Int64 = 0x10000000
    public static let ATTRF_INVERT: Int64 = 0x20000000
    public static let ATTRF_SEL: Int64 = 0x40000000
    public static let ATTRF_UNDERLINE: Int64 = 0x80000000

    private let oColor2: Int
    private let oWinTask: Int
    private let oPixL: Int
    private let oPixR: Int
    private let oPixT: Int
    private let oPixB: Int
    private let oTScrollX: Int
    private let oTScrollY: Int

    private let oScrollX: Int
    private let oScrollY: Int
    private let oWinL: Int
    private let oWinR: Int
    private let oWinT: Int
    private let oWinB: Int

    public init(_ k: Kernel) throws {
        self.k = k
        m = k.mem
        let o: Offsets = k.o
        textGlobal = o.global("text")
        oWidth = try o.dc("width")
        oWI = try o.dc("width_internal")
        oHeight = try o.dc("height")
        oFlags = try o.dc("flags")
        oColor = try o.dc("color")
        oBk = try o.dc("bkcolor")
        oBody = try o.dc("body")
        oDb = try o.dc("depth_buf")
        oDbZ = try o.dc("db_z")
        oCurX = try o.dc("cur_x")
        oCurY = try o.dc("cur_y")
        oNearest = try o.dc("nearest_dist")
        oMinX = try o.dc("min_x")
        oMaxX = try o.dc("max_x")
        oMinY = try o.dc("min_y")
        oMaxY = try o.dc("max_y")
        oCollision = try o.dc("collision_cnt")
        oDither = try o.dc("dither_probability_u16")
        oSig = try o.dc("dc_signature")

        grDcOff = try o.member("CGrGlbls", "dc")
        grDc2Off = try o.member("CGrGlbls", "dc2")
        grDc1Off = try o.member("CGrGlbls", "dc1")
        grTextOff = try o.member("CGrGlbls", "text_base")

        oColor2 = try o.dc("color2")
        oWinTask = try o.dc("win_task")
        oPixL = try o.task("pix_left")
        oPixR = try o.task("pix_right")
        oPixT = try o.task("pix_top")
        oPixB = try o.task("pix_bottom")
        oTScrollX = try o.task("scroll_x")
        oTScrollY = try o.task("scroll_y")

        oScrollX = try o.task("scroll_x")
        oScrollY = try o.task("scroll_y")
        oWinL = try o.task("win_left")
        oWinR = try o.task("win_right")
        oWinT = try o.task("win_top")
        oWinB = try o.task("win_bottom")
    }

    /** Kotlin `x.toInt()` of a Long address, used as an (unchecked) arena index. */
    @inline(__always) private func i32(_ v: Int64) -> Int { Int(Int32(truncatingIfNeeded: v)) }
    /** Kotlin `.toInt().toLong()`. */
    @inline(__always) private func s32(_ v: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: v)) }

    public func initScreens() throws {
        let dc = try k.callHolyC("DCNew", Int64(Kernel.W), Int64(Kernel.H), 0, 0)
        let dc2 = try k.callHolyC("DCNew", Int64(Kernel.W), Int64(Kernel.H), 0, 0)
        grDc = dc; grDc2 = dc2
        m.fill(i32(m.ld8(i32(dc) + oBody)), 0xFF, Kernel.W * Kernel.H)
        m.st8(o.grAddr + grDcOff, dc)
        m.st8(o.grAddr + grDc2Off, dc2)
        m.st8(o.grAddr + grDc1Off, dc2)
        m.st4(i32(dc) + oFlags, m.ld4(i32(dc) + oFlags) | Gfx.DCF_SCRN_BITMAP | 0x20000) // DCF_ON_TOP
        m.st4(i32(dc2) + oFlags, m.ld4(i32(dc2) + oFlags) | Gfx.DCF_SCRN_BITMAP)
        textBase = try m.calloc(80 * 60 * 4)
        m.st8(o.grAddr + grTextOff, Int64(textBase))
        // window z-buffer (one U16 per text cell; all zero = nothing covers the window)
        m.st8(o.grAddr + (try o.member("CGrGlbls", "win_z_buf")), Int64(try m.calloc(80 * 60 * 2)))
        let unc = try m.malloc(65536 / 8)
        m.fill(unc, 0xFF, 65536 / 8)
        m.st8(o.grAddr + (try o.member("CGrGlbls", "win_uncovered_bitmap")), Int64(unc))
        m.st8(o.grAddr + (try o.member("CGrGlbls", "vga_text_cache")), Int64(try m.calloc(80 * 60 * 2)))
        fontAddr = try m.malloc(2048)
        let font: [UInt8] = k.font
        m.writeBytes(fontAddr, font)
    }

    // ------------------------------------------------------------ GrPlot0

    @inline(__always) private func dcAddr(_ dc: Int64) throws -> Int {
        return try m.check(dc == 0 ? grDc : dc, 8)
    }

    /** Port of TempleOS GrPlot0: 2D, no clipping/transformation/thick. */
    public func plot0(_ dc0: Int64, _ x: Int64, _ y: Int64) throws {
        let dc = try dcAddr(dc0)
        let flags = m.ld4(dc + oFlags)
        if flags & Gfx.DCF_LOCATE_NEAREST != 0 {
            let dx = x &- s32(m.ld4(dc + oCurX)); let dy = y &- s32(m.ld4(dc + oCurY))
            let dist = dx &* dx &+ dy &* dy
            if dist <= m.ld8(dc + oNearest) { m.st8(dc + oNearest, dist) }
        }
        if flags & Gfx.DCF_RECORD_EXTENTS != 0 {
            if x < m.ld8(dc + oMinX) { m.st8(dc + oMinX, x) }
            if x > m.ld8(dc + oMaxX) { m.st8(dc + oMaxX, x) }
            if y < m.ld8(dc + oMinY) { m.st8(dc + oMinY, y) }
            if y > m.ld8(dc + oMaxY) { m.st8(dc + oMaxY, y) }
        }
        if flags & Gfx.DCF_DONT_DRAW != 0 { return }
        let wi = s32(m.ld4(dc + oWI))
        let d = wi &* y &+ x
        let db = m.ld8(dc + oDb)
        if db != 0 {
            let pa = try m.check(db &+ d &* 4, 4)
            let dbz = m.ld8(dc + oDbZ)
            if dbz >= 0 && dbz <= s32(m.ld4(pa)) { m.st4(pa, dbz) } else { return }
        }
        var color = m.ld4(dc + oColor)
        let c1rop = (color >> 24) & 0xFF
        if c1rop & 0xC0 != 0 {
            let swap: Bool
            if c1rop & 0x80 != 0 {
                swap = (k.nextRand(k.current) & 0xFFFF) < m.ld8(dc + oDither) // GrPlot0: RandU16 of the drawing task
            } else { swap = ((x ^ y) & 1) != 0 }
            if swap {
                // color.c1.rop=color.c0.rop; color.c0=color.c1
                let c0rop = (color >> 8) & 0xFF
                let c1c = (color >> 16) & 0xFF
                color = c1c | (c0rop << 8)
            }
        }
        let body = m.ld8(dc + oBody)
        let dst = try m.check(body &+ d, 1)
        switch Int((color >> 8) & 0xFF) {
        case 0, 3: m.st1(dst, color & 0xFF)
        case 2:
            let c = m.ld1(dst)
            if c != 0xFF && c != (m.ld4(dc + oBk) & 0xFF) { m.st8(dc + oCollision, m.ld8(dc + oCollision) &+ 1) }
        case 1: m.st1(dst, m.ld1(dst) ^ (color & 0xFF))
        default: m.st1(dst, color & 0xFF)
        }
    }

    /**
     * Native replacement for TempleOS GrFloodFillRay (which needs a 16 MiB work
     * buffer). Fills the 4-connected region of pixels equal to dc->color2 (or not
     * equal to it with DCF_FILL_NOT_COLOR) through GrPlot0, so ROP, dithering
     * and the depth buffer behave as in TempleOS. Returns pixels changed.
     */
    public func floodFillRay(_ dc0: Int64, _ x0: Int64, _ y0: Int64, _ z: Int64) throws -> Int64 {
        let dc = try dcAddr(dc0)
        let flags = m.ld4(dc + oFlags)
        let w = i32(m.ld4(dc + oWidth)); let h = i32(m.ld4(dc + oHeight))
        let wi = i32(m.ld4(dc + oWI))
        let body = m.ld8(dc + oBody)
        let target = m.ld4(dc + oColor2) & 0xFF
        let notColor = flags & 0x8000 != 0
        var x = x0; var y = y0
        var left: Int64 = 0; var top: Int64 = 0; var right = Int64(w - 1); var bottom = Int64(h - 1)
        if flags & Gfx.DCF_SCRN_BITMAP != 0 {
            let tk = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ (m.ld8(tk + oTScrollX) &+ m.ld8(tk + oPixL))
            y = y &+ (m.ld8(tk + oTScrollY) &+ m.ld8(tk + oPixT))
            left = max(left, m.ld8(tk + oPixL)); right = min(right, m.ld8(tk + oPixR))
            top = max(top, m.ld8(tk + oPixT)); bottom = min(bottom, m.ld8(tk + oPixB))
        }
        if x < left || x > right || y < top || y > bottom { return 0 }
        // width/height/width_internal are program-writable: a row must fit in the stride
        if w <= 0 || h <= 0 || wi < w { try m.fault(body) }
        let bodyA = try m.checkRows(body, Int64(wi), Int64(h), Int64(w))
        let pix = m.ptr(0)
        // visited bitmap (Kotlin java.util.BitSet(w * h)); w, h >= 1 here
        let nVis = max(w * h, 1)
        let visited = UnsafeMutablePointer<Bool>.allocate(capacity: nVis)
        visited.initialize(repeating: false, count: nVis)
        defer { visited.deallocate() }
        @inline(__always) func match(_ xx: Int, _ yy: Int) -> Bool {
            let c = Int64(pix[bodyA + yy * wi + xx])
            return notColor ? c != target : c == target
        }
        var stackX = [Int](); var stackY = [Int]()
        stackX.reserveCapacity(4096); stackY.reserveCapacity(4096)
        stackX.append(Int(Int32(truncatingIfNeeded: x))); stackY.append(Int(Int32(truncatingIfNeeded: y)))
        var count: Int64 = 0
        let savedDbZ = m.ld8(dc + oDbZ)
        m.st8(dc + oDbZ, z)
        // Plotting in screen coordinates: temporarily clear DCF_SCRN_BITMAP is not
        // needed since plot0 takes screen coordinates.
        let l = i32(left); let r = i32(right); let t = i32(top); let b = i32(bottom)
        while let sx = stackX.popLast() {
            let sy = stackY.removeLast()
            if visited[sy * w + sx] || !match(sx, sy) { continue }
            var x1 = sx
            while x1 > l && !visited[sy * w + x1 - 1] && match(x1 - 1, sy) { x1 -= 1 }
            var x2 = sx
            while x2 < r && !visited[sy * w + x2 + 1] && match(x2 + 1, sy) { x2 += 1 }
            for xx in x1...x2 {
                visited[sy * w + xx] = true
                try plot0(dc0, Int64(xx), Int64(sy))
                count += 1
            }
            for side in 0..<2 {
                let ny = side == 0 ? sy - 1 : sy + 1
                if ny < t || ny > b { continue }
                var xx = x1
                while xx <= x2 {
                    if !visited[ny * w + xx] && match(xx, ny) {
                        stackX.append(xx); stackY.append(ny)
                        while xx <= x2 && !visited[ny * w + xx] && match(xx, ny) { xx += 1 }
                    }
                    xx += 1
                }
            }
        }
        m.st8(dc + oDbZ, savedDbZ)
        return count
    }

    public func peek0(_ dc0: Int64, _ x: Int64, _ y: Int64) throws -> Int64 {
        let dc = try dcAddr(dc0)
        let wi = s32(m.ld4(dc + oWI))
        return m.ld1(try m.check(m.ld8(dc + oBody) &+ wi &* y &+ x, 1))
    }

    // ------------------------------------------------------------ palette

    public func paletteSet(_ i: Int, _ bgr48: Int64) {
        if i < 0 || i > 15 { return }
        let b = Int(ushr(bgr48 & 0xFFFF, 8))
        let g = Int(ushr(ushr(bgr48, 16) & 0xFFFF, 8))
        let r = Int(ushr(ushr(bgr48, 32) & 0xFFFF, 8))
        k.palette[i] = Int32(truncatingIfNeeded: (0xFF << 24) | (r << 16) | (g << 8) | b)
    }

    public func paletteGet(_ i: Int) -> Int64 {
        if i < 0 || i > 15 { return 0 }
        let c = Int64(UInt32(bitPattern: k.palette[i]))
        let r = (c >> 16) & 0xFF; let g = (c >> 8) & 0xFF; let b = c & 0xFF
        return (b * 0x101) | ((g * 0x101) << 16) | ((r * 0x101) << 32)
    }

    // ------------------------------------------------------------ text layer

    /** Resolves text cell coordinates like TempleOS _TEXT_CHAR; returns the cell index or -1. */
    private func textCell(_ task0: Int64, _ allowBorder: Bool, _ x0: Int64, _ y0: Int64) throws -> Int {
        let task: Int64
        if task0 == 0 {
            guard let cur = k.current else { return -1 }
            task = Int64(cur.fsAddr)
        } else { task = task0 }
        let tp = try m.check(task, 8)
        var x = (m.ld8(tp + oScrollX) >> 3) &+ x0
        var y = (m.ld8(tp + oScrollY) >> 3) &+ y0
        let lo: Int64 = allowBorder ? -1 : 0
        if x < lo { return -1 }
        x = x &+ m.ld8(tp + oWinL)
        if x > m.ld8(tp + oWinR) &+ (allowBorder ? 1 : 0) { return -1 }
        if x < 0 || x >= 80 { return -1 }
        if y < lo { return -1 }
        y = y &+ m.ld8(tp + oWinT)
        if y > m.ld8(tp + oWinB) &+ (allowBorder ? 1 : 0) { return -1 }
        if y < 0 || y >= 60 { return -1 }
        return Int(y * 80 + x)
    }

    public func textChar(_ task: Int64, _ allowBorder: Bool, _ x: Int64, _ y: Int64, _ d: Int64) throws -> Bool {
        let c = try textCell(task, allowBorder, x, y)
        if c < 0 { return false }
        m.st4(textBase + c * 4, d)
        return true
    }

    public func textAttr(_ task: Int64, _ x: Int64, _ y: Int64, _ attr: Int64) throws -> Bool {
        let c = try textCell(task, false, x, y)
        if c < 0 { return false }
        let old = m.ld4(textBase + c * 4)
        m.st4(textBase + c * 4, (old & 0xFF) | (attr & 0xFFFFFF00))
        return true
    }

    /** Kotlin IntArray cells are `[Int]` holding sign-extended 32-bit values. */
    public func copyTextCellsToArena(_ cells: [Int]) {
        for i in 0..<cells.count { m.st4(textBase + i * 4, Int64(cells[i])) }
    }

    public func copyTextCellsFromArena(_ cells: inout [Int]) {
        for i in 0..<cells.count { cells[i] = Int(Int32(truncatingIfNeeded: m.ld4(textBase + i * 4))) }
    }

    private lazy var oPanX = o.member("CGrGlbls", "pan_text_x")
    private lazy var oPanY = o.member("CGrGlbls", "pan_text_y")
    private lazy var oHideRow = o.member("CGrGlbls", "hide_row")
    private lazy var oHideCol = o.member("CGrGlbls", "hide_col")
    private lazy var oTextFont = o.member("CTextGlbls", "font")
    /** TempleOS's `text` (CTextGlbls), resolved when the kernel boots, as in Kotlin: a program may declare its own
     *  global named `text` (Demo/Games/Maze.HC's text cells), which must not be taken for it. */
    private let textGlobal: Int
    private var fontBuf = [UInt8](repeating: 0, count: 256 * 8)

    /**
     * The font of the text layer: TempleOS draws with text.font, which programs replace or edit
     * (Demo/Graphics/CharAnimation.HC animates the space glyph, CharDemo makes its own tiles).
     */
    private func currentFont() -> [UInt8] {
        let p = m.ld8(textGlobal + oTextFont)
        guard let a = try? m.check(p, fontBuf.count) else { return k.font }
        for i in 0..<fontBuf.count { fontBuf[i] = UInt8(truncatingIfNeeded: m.ld1(a + i)) }
        return fontBuf
    }

    /** Renders 80x60 text cells (TempleOS text_base layout) into an indexed frame. */
    public func renderText(_ cells: [Int], _ frame: inout [UInt8]) {
        frame.withUnsafeMutableBufferPointer { fb in renderText(cells, fb.baseAddress!) }
    }

    /**
     * Renders 80x60 text cells (TempleOS text_base layout) into an indexed frame, as Adam/Gr/GrScrn.HC
     * GrUpdateTextBG and GrUpdateTextFG do: every cell's background, then every glyph (shifted by the
     * cell's own 5-bit x/y offsets in bits 16..25); ATTRF_SEL inverts both colors, ATTRF_INVERT swaps
     * them, ATTRF_BLINK swaps them while Blink() (2.5 Hz) is on; gr.pan_text_x/y (-7..7) move the whole
     * layer by pixels and, with gr.hide_col/hide_row, give up one column/row, blanking the edge strips.
     */
    public func renderText(_ cells: [Int], _ frame: UnsafeMutablePointer<UInt8>) {
        let font = currentFont()
        let blink = (k.jiffies() * 5 / 1000) & 1 != 0 // Kernel/KMisc.HC Blink(2.5)
        let gr = o.grAddr
        let panX = Int(min(max(m.ld8(gr + oPanX), -7), 7)); m.st8(gr + oPanX, Int64(panX))
        let panY = Int(min(max(m.ld8(gr + oPanY), -7), 7)); m.st8(gr + oPanY, Int64(panY))
        let hideCol = m.ld1(gr + oHideCol) != 0, hideRow = m.ld1(gr + oHideRow) != 0
        var numCols = 80, numRows = 60, srcCol = 0, srcRow = 0, x0 = 0, y0 = 0
        if panX != 0 || hideCol {
            let j = abs(panX) / 8 + 1
            numCols -= j
            if panX < 0 { srcCol = j; x0 = 8 * j + panX } else { x0 = panX }
        }
        if panY != 0 || hideRow {
            let j = abs(panY) / 8 + 1
            numRows -= j
            if panY < 0 { srcRow = j; y0 = 8 * j + panY } else { y0 = panY }
        }
        let w = Kernel.W, h = Kernel.H
        if numCols != 80 || numRows != 60 { frame.initialize(repeating: 0, count: w * h) } // the blanked edge strips
        func colorOf(_ cell: Int64) -> Int {
            var c = Int((cell >> 8) & 0xFF)
            if cell & Gfx.ATTRF_SEL != 0 { c ^= 0xFF }
            if cell & Gfx.ATTRF_INVERT != 0 { c = ((c << 4) | (c >> 4)) & 0xFF }
            if cell & Gfx.ATTRF_BLINK != 0 && blink { c = ((c << 4) | (c >> 4)) & 0xFF }
            return c
        }
        cells.withUnsafeBufferPointer { cb in
            let cp = cb.baseAddress!
            // pass 1: backgrounds
            for row in 0..<numRows {
                for col in 0..<numCols {
                    let cell = Int64(cp[(srcRow + row) * 80 + srcCol + col]) & 0xFFFFFFFF
                    let bg = UInt8((colorOf(cell) >> 4) & 15)
                    let bx = x0 + col * 8, by = y0 + row * 8
                    for r in 0..<8 {
                        let y = by + r
                        if y < 0 || y >= h { continue }
                        let p = y * w
                        for c in 0..<8 { let x = bx + c; if x >= 0 && x < w { frame[p + x] = bg } }
                    }
                }
            }
            // pass 2: glyphs
            for row in 0..<numRows {
                for col in 0..<numCols {
                    let cell = Int64(cp[(srcRow + row) * 80 + srcCol + col]) & 0xFFFFFFFF
                    let fg = UInt8(colorOf(cell) & 15)
                    let ch = Int(cell & 0xFF)
                    var ox = Int((cell >> 16) & 0x1F); if ox & 0x10 != 0 { ox |= ~0x1F }
                    var oy = Int((cell >> 21) & 0x1F); if oy & 0x10 != 0 { oy |= ~0x1F }
                    let bx = x0 + col * 8 + ox, by = y0 + row * 8 + oy
                    for r in 0..<8 {
                        var bits = Int(font[ch * 8 + r])
                        if r == 7 && cell & Gfx.ATTRF_UNDERLINE != 0 { bits = 0xFF }
                        if bits == 0 { continue }
                        let y = by + r
                        if y < 0 || y >= h { continue }
                        let p = y * w
                        for c in 0..<8 where (bits >> c) & 1 != 0 { let x = bx + c; if x >= 0 && x < w { frame[p + x] = fg } }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ composition

    private func bodyOf(_ dc: Int64) -> Int { i32(m.ld8(i32(dc) + oBody)) }

    /**
     * True once anything was drawn on gr.dc, the persistent screen layer (it starts all
     * TRANSPARENT). Programs like ElephantWalk, MouseDemo and SunMoon draw only there.
     */
    /**
     * The text layer was panned or given another font (Demo/Graphics/PanText.HC, CharAnimation.HC):
     * like drawing, that is only visible on the TempleOS screen, not in the console view.
     */
    public func textLayerTouched() -> Bool {
        let gr = o.grAddr
        if m.ld8(gr + oPanX) != 0 || m.ld8(gr + oPanY) != 0 || m.ld1(gr + oHideCol) != 0 || m.ld1(gr + oHideRow) != 0 { return true }
        if m.ld8(textGlobal + oTextFont) != Int64(fontAddr) { return true }
        let f: [UInt8] = k.font
        for i in 0..<min(f.count, 256 * 8) where UInt8(truncatingIfNeeded: m.ld1(fontAddr + i)) != f[i] { return true }
        return false
    }

    public func screenTouched() -> Bool {
        // gr.dc->body is program-writable: a program that overwrote it (wild writes) has used the screen
        let body = m.ld8(Int(grDc) + oBody)
        if body < 0 || body + Int64(Kernel.W * Kernel.H) > Int64(m.size) { return true }
        let s1 = Int(body)
        let words = (m.base + s1).assumingMemoryBound(to: Int64.self)
        for w in 0..<(Kernel.W * Kernel.H / 8) where words[w] != -1 { return true }
        return false
    }

    /** Copies a host frame into gr.dc2's body (the draw_it target). */
    public func loadScreen(_ frame: [UInt8]) throws {
        try frame.withUnsafeBufferPointer { fb in try loadScreen(fb.baseAddress!, fb.count) }
    }

    public func loadScreen(_ frame: UnsafePointer<UInt8>, _ count: Int) throws {
        // Kotlin writes whole words at (dst ushr 3)
        let dst = (bodyOf(grDc2) >> 3) << 3
        let n = (count + 7) & ~7
        _ = try m.check(Int64(dst), n)
        memcpy(m.base + dst, frame, count)
    }

    public func aliasForDraw(_ t: HTask) throws -> Int64 {
        let dc = try k.callHolyC("DCAlias", grDc2, Int64(t.fsAddr), task: t)
        return dc
    }

    public func freeDrawAlias(_ dc: Int64) {
        _ = try? k.callHolyC("DCDel", dc)
    }

    /** gr.dc2 with gr.dc blotted on top (TRANSPARENT skipped) into [out]. */
    @discardableResult
    public func composeAndPublish(_ out: inout [UInt8]) throws -> Bool {
        try out.withUnsafeMutableBufferPointer { ob in try composeAndPublish(ob.baseAddress!) }
    }

    /**
     * Composes the screen into [out]; returns false when no pixel changed, so the
     * UI does not convert and upload an identical frame (most programs redraw
     * every frame even when nothing moves).
     */
    @discardableResult
    public func composeAndPublish(_ out: UnsafeMutablePointer<UInt8>) throws -> Bool {
        let n = Kernel.W * Kernel.H / 8
        let s2 = (bodyOf(grDc2) >> 3) << 3
        let s1 = (bodyOf(grDc) >> 3) << 3
        _ = try m.check(Int64(s2), n * 8)
        _ = try m.check(Int64(s1), n * 8)
        let p2 = UnsafeRawPointer(m.base + s2)
        let p1 = UnsafeRawPointer(m.base + s1)
        let op = UnsafeMutableRawPointer(out)
        var i = 0
        var diff: UInt64 = 0
        for w in 0..<n {
            let a = p2.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
            let b = p1.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
            let old = op.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            if b == UInt64.max {
                op.storeBytes(of: a, toByteOffset: i, as: UInt64.self)
            } else {
                for j in 0..<8 {
                    let pb = UInt8(truncatingIfNeeded: b >> UInt64(8 * j))
                    out[i + j] = pb == 0xFF ? UInt8(truncatingIfNeeded: a >> UInt64(8 * j)) : pb
                }
            }
            diff |= old ^ op.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            i += 8
        }
        return diff != 0
    }
}
