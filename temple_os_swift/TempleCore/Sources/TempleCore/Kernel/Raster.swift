import Foundation

/**
 * Native fast paths for the hottest TempleOS graphics primitives (GrPlot,
 * GrPlot1, GrPeek, GrRect, GrHLine, GrVLine, GrBlot). Each reproduces the
 * pixel results, return values, collision counts and random-number usage of
 * the original HolyC in Adam/Gr/GrBitMap.HC and GrPrimatives.HC, which stay
 * compiled as *_HC: rare paths (pen brushes) call them, and the differential
 * test compares both on random inputs. Port of kernel/Raster.kt.
 */
public final class Raster {
    private unowned let k: Kernel
    // Long native loops (huge circles, lines, polygons from program-supplied coordinates)
    // must stay stoppable: poll the VM's hard-stop flag every 64Ki primitive steps.
    private var pollCount = 0
    @inline(__always) private func poll() throws {
        pollCount &+= 1
        if (pollCount & 0xFFFF) == 0 && k.vm.interrupt { throw VmKill("Stopped.") }
    }
    /** Kotlin `k.mem` (the VM arena is created once and never replaced). */
    private let m: Arena
    private var o: Offsets { k.o }

    private let oFlags: Int, oWidth: Int, oWI: Int
    private let oHeight: Int, oColor: Int, oBk: Int
    private let oBody: Int, oDb: Int, oDbZ: Int
    private let oCurX: Int, oCurY: Int, oNearest: Int
    private let oMinX: Int, oMaxX: Int, oMinY: Int, oMaxY: Int
    private let oCollision: Int, oDither: Int
    private let oBrush: Int, oWinTask: Int, oSig: Int
    private let oPixL: Int, oPixR: Int
    private let oPixT: Int, oPixB: Int
    private let oSX: Int, oSY: Int, oSZ: Int

    public static let SCRN: Int64 = 0x4000
    public static let NEAREST: Int64 = 0x800
    public static let DONT_DRAW: Int64 = 0x1000
    public static let EXTENTS: Int64 = 0x10000
    public static let NO_TRANSPARENTS: Int64 = 0x100000
    public static let ROP_EQU = 0, ROP_XOR = 1, ROP_COLLISION = 2, ROP_MONO = 3
    public static let DITHER: Int64 = 0x40, PROB_DITHER: Int64 = 0x80
    public static let ROPBF_HALF_RANGE_COLOR: Int64 = 0x10, ROPBF_TWO_SIDED: Int64 = 0x20
    public static let ROPF_PROBABILITY_DITHER: Int64 = 0x8000_0000
    /** GR_SCALE (Prelude.HC: 32.32 fixed point) as the F64 that sum/GR_SCALE divides by. */
    public static let GR_SCALE_F = 4294967296.0

    private let oR: Int, oDX: Int, oDY: Int, oDZ: Int
    private let oTransform: Int
    private let oSym: Int
    private let oCircleLo: Int
    private let oCircleHi: Int
    private let oLs: Int
    private let oTo8Bits: Int, oTo8Colors: Int, oTextFont: Int, textAddr: Int

    public init(_ k: Kernel) throws {
        self.k = k
        m = k.mem
        let o: Offsets = k.o
        oFlags = try o.dc("flags"); oWidth = try o.dc("width"); oWI = try o.dc("width_internal")
        oHeight = try o.dc("height"); oColor = try o.dc("color"); oBk = try o.dc("bkcolor")
        oBody = try o.dc("body"); oDb = try o.dc("depth_buf"); oDbZ = try o.dc("db_z")
        oCurX = try o.dc("cur_x"); oCurY = try o.dc("cur_y"); oNearest = try o.dc("nearest_dist")
        oMinX = try o.dc("min_x"); oMaxX = try o.dc("max_x"); oMinY = try o.dc("min_y"); oMaxY = try o.dc("max_y")
        oCollision = try o.dc("collision_cnt"); oDither = try o.dc("dither_probability_u16")
        oBrush = try o.dc("brush"); oWinTask = try o.dc("win_task"); oSig = try o.dc("dc_signature")
        oPixL = try o.task("pix_left"); oPixR = try o.task("pix_right")
        oPixT = try o.task("pix_top"); oPixB = try o.task("pix_bottom")
        oSX = try o.task("scroll_x"); oSY = try o.task("scroll_y"); oSZ = try o.task("scroll_z")
        oR = try o.dc("r"); oDX = try o.dc("x"); oDY = try o.dc("y"); oDZ = try o.dc("z")
        oTransform = try o.dc("transform")
        oSym = try o.dc("sym")
        oCircleLo = try o.member("CGrGlbls", "circle_lo")
        oCircleHi = try o.member("CGrGlbls", "circle_hi")
        oLs = try o.dc("ls")
        oTo8Bits = try o.member("CGrGlbls", "to_8_bits"); oTo8Colors = try o.member("CGrGlbls", "to_8_colors")
        oTextFont = try o.member("CTextGlbls", "font"); textAddr = o.global("text")
    }

    /** Kotlin `.toInt().toLong()`. */
    @inline(__always) private func s32(_ v: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: v)) }
    /** Kotlin `.toInt()` of a Long (32-bit truncation, as an Int). */
    @inline(__always) private func i32(_ v: Int64) -> Int { Int(Int32(truncatingIfNeeded: v)) }
    /** Kotlin Math.abs(Long): MIN stays MIN. */
    @inline(__always) private func kabs(_ v: Int64) -> Int64 { v < 0 ? 0 &- v : v }
    @inline(__always) private func postInc(_ v: inout Int64) -> Int64 { let o = v; v = v &+ 1; return o }
    @inline(__always) private func postDec(_ v: inout Int64) -> Int64 { let o = v; v = v &- 1; return o }

    @inline(__always) private func dcp(_ dc: Int64) throws -> Int { try m.check(dc == 0 ? k.gfx.grDc : dc, 8) }
    @inline(__always) private func color0rop(_ dc: Int) -> Int { Int((m.ld4(dc + oColor) >> 8) & 0xFF) }

    /** Dithering draws from the current task's generator, as GrPlot0's RandU16 does on TempleOS. */
    @inline(__always) private func rand16() -> Int64 { k.nextRand(k.current) & 0xFFFF }

    // ---------------------------------------------------------------- GrPlot / GrPlot1 / GrPeek

    /** GrPlot1: clipping, no transformation or thick; db_z already set. */
    public func plot1(_ dc0: Int64, _ x0: Int64, _ y0: Int64) throws -> Int64 {
        try poll()
        let dc = try dcp(dc0)
        if m.ld8(dc + oBrush) != 0 { return try k.callHolyC("GrPlot1_HC", Int64(dc), x0, y0) }
        var x = x0; var y = y0
        let flags = m.ld4(dc + oFlags)
        let w = s32(m.ld4(dc + oWidth)); let h = s32(m.ld4(dc + oHeight))
        if flags & Raster.SCRN != 0 {
            let t = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ (m.ld8(t + oPixL) &+ m.ld8(t + oSX))
            y = y &+ (m.ld8(t + oPixT) &+ m.ld8(t + oSY))
            if x >= m.ld8(t + oPixL) && x <= m.ld8(t + oPixR) && y >= m.ld8(t + oPixT) && y <= m.ld8(t + oPixB) &&
                x >= 0 && x < w && y >= 0 && y < h {
                try k.gfx.plot0(Int64(dc), x, y)
            }
        } else if x >= 0 && x < w && y >= 0 && y < h { try k.gfx.plot0(Int64(dc), x, y) }
        return 1
    }

    /** GrPlot: like GrPlot1 with the depth buffer disabled. */
    public func plot(_ dc0: Int64, _ x: Int64, _ y: Int64) throws -> Int64 {
        let dc = try dcp(dc0)
        if m.ld8(dc + oBrush) != 0 { return try k.callHolyC("GrPlot_HC", Int64(dc), x, y) }
        let db = m.ld8(dc + oDb)
        if db != 0 { m.st8(dc + oDb, 0) }
        defer { if db != 0 { m.st8(dc + oDb, db) } }
        _ = try plot1(Int64(dc), x, y)
        return 1
    }

    public func peek(_ dc0: Int64, _ x0: Int64, _ y0: Int64) throws -> Int64 {
        let dc = try dcp(dc0)
        var x = x0; var y = y0
        let flags = m.ld4(dc + oFlags)
        let w = s32(m.ld4(dc + oWidth)); let h = s32(m.ld4(dc + oHeight))
        if flags & Raster.SCRN != 0 {
            let t = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ (m.ld8(t + oPixL) &+ m.ld8(t + oSX))
            y = y &+ (m.ld8(t + oPixT) &+ m.ld8(t + oSY))
            if !(x >= m.ld8(t + oPixL) && x <= m.ld8(t + oPixR)) || !(y >= m.ld8(t + oPixT) && y <= m.ld8(t + oPixB)) ||
                !(x >= 0 && x < w) || !(y >= 0 && y < h) { return -1 }
        } else if !(x >= 0 && x < w) || !(y >= 0 && y < h) { return -1 }
        let wi = s32(m.ld4(dc + oWI))
        return m.ld1(try m.check(m.ld8(dc + oBody) &+ wi &* y &+ x, 1))
    }

    // ---------------------------------------------------------------- GrRect

    public func rect(_ dc0: Int64, _ x0: Int64, _ y0: Int64, _ w: Int64, _ h: Int64) throws -> Int64 {
        try poll()
        let dc = try dcp(dc0)
        let flags = m.ld4(dc + oFlags)
        var x = x0; var y = y0
        var tk = 0
        if flags & Raster.SCRN != 0 {
            tk = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ m.ld8(tk + oSX); y = y &+ m.ld8(tk + oSY)
        }
        var w1: Int64 = x < 0 ? 0 &- x : 0
        var h1: Int64 = y < 0 ? 0 &- y : 0
        var w2 = w; var h2 = h
        if flags & Raster.SCRN != 0 { x = x &+ m.ld8(tk + oPixL); y = y &+ m.ld8(tk + oPixT) }
        if flags & Raster.NEAREST != 0 {
            let cx = s32(m.ld4(dc + oCurX)); let cy = s32(m.ld4(dc + oCurY))
            let dist: Int64 = (cx >= x && cx <= x &+ w && cy >= y && cy <= y &+ h) ? 0 :
                sqr(((x &+ w) >> 1) &- cx) &+ sqr(((y &+ h) >> 1) &- cy)
            if dist <= m.ld8(dc + oNearest) { m.st8(dc + oNearest, dist) }
        }
        if flags & Raster.SCRN != 0 {
            if x &+ w1 < 0 { w1 = 0 &- x }
            if x &+ w2 > m.ld8(tk + oPixR) &+ 1 { w2 = m.ld8(tk + oPixR) &+ 1 &- x }
            if y &+ h1 < 0 { h1 = 0 &- y }
            if y &+ h2 > m.ld8(tk + oPixB) &+ 1 { h2 = m.ld8(tk + oPixB) &+ 1 &- y }
        }
        let dw = s32(m.ld4(dc + oWidth)); let dh = s32(m.ld4(dc + oHeight))
        if x &+ w2 > dw { w2 = dw &- x }
        if y &+ h2 > dh { h2 = dh &- y }
        if !(w1 < w2 && w2 <= w && h1 < h2 && h2 <= h) { return 0 }
        if flags & Raster.EXTENTS != 0 { extents(dc, x &+ w1, x &+ w2 &- 1, y &+ h1, y &+ h2 &- 1) }
        if flags & Raster.DONT_DRAW != 0 { return 1 }
        let color = m.ld4(dc + oColor)
        let wi = s32(m.ld4(dc + oWI))
        let body = m.ld8(dc + oBody)
        let xs = i32(x &+ w1); let xe = i32(x &+ w2) // exclusive
        let ys = i32(y &+ h1); let ye = i32(y &+ h2)
        let n = xe - xs
        let base = try m.checkRows(body &+ wi &* Int64(ys) &+ Int64(xs), wi, Int64(ye - ys), Int64(n))
        let wiI = i32(wi)
        let c0rop = Int((color >> 8) & 0xFF)
        let c1rop = (color >> 24) & 0xFF
        let c0 = color & 0xFF; let c1 = (color >> 16) & 0xFF
        let p = m.ptr(0)
        if c0rop == Raster.ROP_COLLISION {
            let bk = m.ld4(dc + oBk) & 0xFF
            var cnt: Int64 = 0
            for r in 0..<max(ye - ys, 0) {
                let row = base + r * wiI
                for i in 0..<max(n, 0) { let c = Int64(p[row + i]); if c != 0xFF && c != bk { cnt += 1 } }
            }
            m.st8(dc + oCollision, m.ld8(dc + oCollision) &+ cnt)
            return cnt
        }
        let xor = c0rop == Raster.ROP_XOR
        if c1rop & (Raster.DITHER | Raster.PROB_DITHER) != 0 {
            if c1rop & Raster.PROB_DITHER != 0 {
                let prob = m.ld8(dc + oDither)
                var cur = rand16() < prob ? c1 : c0
                for r in 0..<max(ye - ys, 0) {
                    fillRow(base + r * wiI, n, cur, xor)
                    cur = rand16() < prob ? c1 : c0
                }
            } else {
                let b0 = UInt8(truncatingIfNeeded: c0), b1 = UInt8(truncatingIfNeeded: c1)
                for r in 0..<max(ye - ys, 0) {
                    let row = p + (base + r * wiI)
                    let yy = ys + r
                    for i in 0..<max(n, 0) {
                        let c = ((xs + i) ^ yy) & 1 == 0 ? b0 : b1
                        if xor { row[i] ^= c } else { row[i] = c }
                    }
                }
            }
        } else {
            for r in 0..<max(ye - ys, 0) { fillRow(base + r * wiI, n, c0, xor) }
        }
        return Int64(ye - ys) &* Int64(n)
    }

    @inline(__always) private func fillRow(_ a: Int, _ n: Int, _ c: Int64, _ xor: Bool) {
        if !xor { m.fill(a, Int(Int32(truncatingIfNeeded: c)), n) }
        else {
            let p = m.ptr(a); let b = UInt8(truncatingIfNeeded: c)
            for i in 0..<max(n, 0) { p[i] ^= b }
        }
    }

    @inline(__always) private func sqr(_ v: Int64) -> Int64 { v &* v }

    @inline(__always) private func extents(_ dc: Int, _ x1: Int64, _ x2: Int64, _ y1: Int64, _ y2: Int64) {
        if x1 < m.ld8(dc + oMinX) { m.st8(dc + oMinX, x1) }
        if x2 > m.ld8(dc + oMaxX) { m.st8(dc + oMaxX, x2) }
        if y1 < m.ld8(dc + oMinY) { m.st8(dc + oMinY, y1) }
        if y2 > m.ld8(dc + oMaxY) { m.st8(dc + oMaxY, y2) }
    }

    // ---------------------------------------------------------------- GrPutChar (Adam/Gr/GrBitMap.HC)

    /**
     * Native GrPutChar: one 8x8 glyph with clipping (2D, no transformation). Every GrPrint goes through it,
     * so status lines cost about 400 VM instructions per character interpreted. Same memory traffic as the
     * original: the glyph row is read as a U16 at the font byte before it when x is not 8-aligned
     * (`*src(U16 *)>>bit_shift`), and the body is read and written as aligned I64 words with the leading and
     * trailing masks (`dc->body+kk1&~7`: HolyC's & binds tighter than +). The window-covered path of the
     * original writes the same pixels here (IsPixCovered0 is FALSE: one window per kernel). Font and the
     * to_8_bits / to_8_colors tables are read from the arena (FontEd and programs may replace text.font).
     */
    public func putChar(_ dc0: Int64, _ x0: Int64, _ y0: Int64, _ ch0: Int64) throws -> Int64 {
        let dc = try m.check(dc0, 8)
        let ch = ch0 & 0xFF
        let flags = m.ld4(dc + oFlags)
        var x = x0, y = y0
        var tk = 0
        if flags & Raster.SCRN != 0 {
            tk = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ m.ld8(tk + oSX); y = y &+ m.ld8(tk + oSY)
        }
        var w1: Int64 = x < 0 ? 0 &- x : 0
        var h1: Int64 = y < 0 ? 0 &- y : 0
        var w2: Int64 = 8, h2: Int64 = 8
        if flags & Raster.SCRN != 0 { x = x &+ m.ld8(tk + oPixL); y = y &+ m.ld8(tk + oPixT) }
        if flags & Raster.NEAREST != 0 {
            let dist = sqr(x &+ (w2 >> 1) &- s32(m.ld4(dc + oCurX))) &+ sqr(y &+ (h2 >> 1) &- s32(m.ld4(dc + oCurY)))
            if dist <= m.ld8(dc + oNearest) { m.st8(dc + oNearest, dist) }
        }
        if flags & Raster.SCRN != 0 {
            if x &+ w1 < 0 { w1 = 0 &- x }
            if x &+ w2 > m.ld8(tk + oPixR) &+ 1 { w2 = m.ld8(tk + oPixR) &+ 1 &- x }
            if y &+ h1 < 0 { h1 = 0 &- y }
            if y &+ h2 > m.ld8(tk + oPixB) &+ 1 { h2 = m.ld8(tk + oPixB) &+ 1 &- y }
        }
        let dw = s32(m.ld4(dc + oWidth)), dh = s32(m.ld4(dc + oHeight))
        if x &+ w2 > dw { w2 = dw &- x }
        if y &+ h2 > dh { h2 = dh &- y }
        if !(w1 < w2 && w2 <= 8 && h1 < h2 && h2 <= 8) { return 0 }
        if flags & Raster.EXTENTS != 0 { extents(dc, x &+ w1, x &+ w2 &- 1, y &+ h1, y &+ h2 &- 1) }
        if flags & Raster.DONT_DRAW != 0 { return 1 }
        let color = m.ld4(dc + oColor)
        let to8Bits = m.ld8(o.grAddr + oTo8Bits)
        func to8(_ i: Int64) throws -> Int64 { m.ld8(try m.check(to8Bits &+ 8 &* i, 8)) }
        var leading = (0 &- (w1 &+ x)) & 7
        if leading == 0 { leading = 8 }
        var leadingMask = try to8(0xFF >> leading)
        let bitShift = (0 &- x) & 7
        var trailing = (x &+ w2) & 7
        let trailingMask = try to8((0xFF << trailing) & 0xFF)
        if leading &+ trailing > w2 &- w1 { leadingMask |= trailingMask; trailing = 0 }
        let fontPtr = m.ld8(textAddr + oTextFont) &+ 8 &* ch &+ h1
        let wi = s32(m.ld4(dc + oWI))
        let body = m.ld8(dc + oBody)
        let rop = (color >> 8) & 0xFF
        if rop == Int64(Raster.ROP_COLLISION) {
            let bk = m.ld4(dc + oBk) & 0xFF // color=dc->bkcolor.c0.color
            var bit = w1 & 7
            var i = w1
            while i < w2 {
                var k1 = (h1 &+ y) &* wi &+ x
                var src = fontPtr
                var j = h2 &- h1
                while j != 0 {
                    let c = m.ld1(try m.check(body &+ k1 &+ i, 1))
                    if c != 0xFF && c != bk {
                        // the font bit is read only when the pixel test passes (HolyC && short-circuits)
                        if (m.ld1(try m.check(src &+ (bit >> 3), 1)) >> (bit & 7)) & 1 != 0 {
                            m.st8(dc + oCollision, m.ld8(dc + oCollision) &+ 1)
                        }
                    }
                    k1 = k1 &+ wi; src = src &+ 1; j = j &- 1
                }
                i = i &+ 1; bit = bit &+ 1
            }
            return 1
        }
        let colorMask = m.ld8(try m.check(m.ld8(o.grAddr + oTo8Colors) &+ 8 &* (color & 0xFF), 8))
        var kk1 = (h1 &+ y) &* wi &+ x &+ w1
        func rows(_ dst0: Int64, _ src0: Int64, _ mask: Int64) throws {
            var dst = dst0, src = src0
            var j = h2 &- h1
            switch Int(rop) {
            case Raster.ROP_EQU, Raster.ROP_MONO:
                while j != 0 {
                    let bits = try to8((m.ld2(try m.check(src, 2)) >> bitShift) & 0xFF)
                    let a = try m.check(dst, 8); let d = m.ld8(a)
                    m.st8(a, (d & mask) | (((colorMask & bits) | (d & ~bits)) & ~mask))
                    src = src &+ 1; dst = dst &+ wi; j = j &- 1
                }
            case Raster.ROP_XOR:
                if colorMask != 0 {
                    while j != 0 {
                        let bits = try to8((m.ld2(try m.check(src, 2)) >> bitShift) & 0xFF)
                        let a = try m.check(dst, 8); let d = m.ld8(a)
                        m.st8(a, (d & mask) | ((d ^ bits) & ~mask))
                        src = src &+ 1; dst = dst &+ wi; j = j &- 1
                    }
                }
            default: break
            }
        }
        try rows(body &+ (kk1 & ~7), bitShift != 0 ? fontPtr &- 1 : fontPtr, leadingMask)
        kk1 = kk1 &+ 8
        if trailing != 0 { try rows(body &+ (kk1 & ~7), bitShift != 0 ? fontPtr : fontPtr &+ 1, trailingMask) }
        return 1
    }

    // ---------------------------------------------------------------- GrHLine / GrVLine

    public func hline(_ dc0: Int64, _ x1a: Int64, _ x2a: Int64, _ ya: Int64, _ z1a: Int64, _ z2a: Int64) throws -> Int64 {
        return try line1d(dc0, x1a, x2a, ya, z1a, z2a, horizontal: true)
    }

    public func vline(_ dc0: Int64, _ xa: Int64, _ y1a: Int64, _ y2a: Int64, _ z1a: Int64, _ z2a: Int64) throws -> Int64 {
        return try line1d(dc0, y1a, y2a, xa, z1a, z2a, horizontal: false)
    }

    /** Shared port of GrHLine/GrVLine: [a1]..[a2] along the line, [b] across it. */
    private func line1d(_ dc0: Int64, _ a1a: Int64, _ a2a: Int64, _ ba: Int64, _ z1a: Int64, _ z2a: Int64, horizontal: Bool) throws -> Int64 {
        try poll()
        let dc = try dcp(dc0)
        if m.ld8(dc + oDb) == 0 {
            var a1 = a1a; var a2 = a2a
            if a2 < a1 { let t = a1; a1 = a2; a2 = t }
            return horizontal ? try rect(Int64(dc), a1, ba, a2 &- a1 &+ 1, 1) : try rect(Int64(dc), ba, a1, 1, a2 &- a1 &+ 1)
        }
        let flags = m.ld4(dc + oFlags)
        var a1 = a1a; var a2 = a2a; var b = ba; var z1 = z1a; var z2 = z2a
        var tk = 0
        if flags & Raster.SCRN != 0 {
            tk = try m.check(m.ld8(dc + oWinTask), 8)
            let sa = m.ld8(tk + (horizontal ? oSX : oSY)); let sb = m.ld8(tk + (horizontal ? oSY : oSX))
            a1 = a1 &+ sa; a2 = a2 &+ sa; b = b &+ sb
            z1 = z1 &+ m.ld8(tk + oSZ); z2 = z2 &+ m.ld8(tk + oSZ)
        }
        if flags & Raster.EXTENTS != 0 {
            if horizontal { extents(dc, min(a1, a2), max(a1, a2), b, b); extentsX(dc, a1, a2) }
            else { extents(dc, b, b, min(a1, a2), max(a1, a2)) }
        }
        if b < 0 { return 0 }
        if a2 < a1 { var t = a1; a1 = a2; a2 = t; t = z1; z1 = z2; z2 = t }
        if a2 < 0 { return 0 }
        var i: Int64 = 0
        if a1 < 0 { i = 0 &- a1; a1 = 0 }
        var j: Int64 = 0
        if flags & Raster.SCRN != 0 {
            let pa = m.ld8(tk + (horizontal ? oPixL : oPixT))
            let paMax = m.ld8(tk + (horizontal ? oPixR : oPixB))
            a1 = a1 &+ pa; a2 = a2 &+ pa
            if a1 > paMax { return 0 }
            if a2 > paMax { j = a2 &- paMax; a2 = paMax }
            b = b &+ m.ld8(tk + (horizontal ? oPixT : oPixL))
            let pbMax = m.ld8(tk + (horizontal ? oPixB : oPixR))
            if !(b >= 0 && b <= pbMax) || a2 < 0 { return 0 }
        }
        let dw = s32(m.ld4(dc + oWidth)); let dh = s32(m.ld4(dc + oHeight))
        let alim = horizontal ? dw : dh
        let blim = horizontal ? dh : dw
        if a1 >= alim || b >= blim { return 0 }
        let da = a2 &+ j &- (a1 &- i)
        let wi = s32(m.ld4(dc + oWI))
        let step: Int64 = horizontal ? 1 : wi
        var d = horizontal ? wi &* b &+ a1 : wi &* a1 &+ b
        let db0 = m.ld8(dc + oDb)
        var db = db0 &+ d &* 4
        let dz: Int64 = da != 0 ? sdiv((z2 &- z1) &<< 32, da) : 0
        var z = z1 &<< 32
        if i != 0 { z = z &+ i &* dz }
        if a2 >= alim { a2 = alim &- 1 }
        if flags & Raster.NEAREST != 0 {
            let cx = s32(m.ld4(dc + oCurX)); let cy = s32(m.ld4(dc + oCurY))
            let ca = horizontal ? cx : cy; let cb = horizontal ? cy : cx
            var dist: Int64 = (ca >= a1 && ca <= a2) ? 0 : (ca < a1 ? sqr(a1 &- ca) : sqr(ca &- a2))
            dist = dist &+ sqr(b &- cb)
            if dist <= m.ld8(dc + oNearest) { m.st8(dc + oNearest, dist) }
        }
        if flags & Raster.DONT_DRAW != 0 { return 0 }
        let color = m.ld4(dc + oColor)
        let c1rop = (color >> 24) & 0xFF
        let rop0 = Int((color >> 8) & 0xFF)
        var cc0 = color & 0xFF; var cc1 = (color >> 16) & 0xFF
        let dither = c1rop & (Raster.DITHER | Raster.PROB_DITHER) != 0
        let prob = c1rop & Raster.PROB_DITHER != 0
        let dprob = m.ld8(dc + oDither)
        var cur: Int64
        if dither {
            if prob { cur = rand16() < dprob ? cc1 : cc0 }
            else {
                let px = horizontal ? a1 : b; let py = horizontal ? b : a1
                if (px ^ py) & 1 != 0 { let t = cc0; cc0 = cc1; cc1 = t }
                cur = cc0
            }
        } else { cur = cc0 }
        let bk = m.ld4(dc + oBk) & 0xFF
        let body = m.ld8(dc + oBody)
        var res: Int64 = 0
        var a = a1
        var swapState = false
        let dbStep = step &* 4
        while a <= a2 {
            let dbp = try m.check(db, 4)
            let zi = s32(z >> 32)
            if zi >= 0 && zi <= s32(m.ld4(dbp)) {
                m.st4(dbp, zi)
                let dst = try m.check(body &+ d, 1)
                switch rop0 {
                case 2: // ROP_COLLISION
                    let c2 = m.ld1(dst); if c2 != 0xFF && c2 != bk { m.st8(dc + oCollision, m.ld8(dc + oCollision) &+ 1) }
                case 1: // ROP_XOR
                    m.st1(dst, m.ld1(dst) ^ cur)
                default: m.st1(dst, cur)
                }
                res += 1
            }
            if dither {
                if prob { cur = rand16() < dprob ? cc1 : cc0 }
                else { swapState = !swapState; cur = swapState ? cc1 : cc0 }
            }
            d = d &+ step
            a &+= 1
            db = db &+ dbStep
            z = z &+ dz
        }
        return res
    }

    private func extentsX(_ dc: Int, _ a1: Int64, _ a2: Int64) {
        // GrHLine records both endpoints separately (already covered by extents()).
    }

    // ---------------------------------------------------------------- GrBlot

    public func blot(_ dc0: Int64, _ x0: Int64, _ y0: Int64, _ img0: Int64) throws -> Int64 {
        let dc = try dcp(dc0)
        let img = try m.check(img0, 8)
        let flags = m.ld4(dc + oFlags)
        var x = x0; var y = y0
        var tk = 0
        if flags & Raster.SCRN != 0 {
            tk = try m.check(m.ld8(dc + oWinTask), 8)
            x = x &+ m.ld8(tk + oSX); y = y &+ m.ld8(tk + oSY)
        }
        var w1: Int64 = x < 0 ? 0 &- x : 0
        var h1: Int64 = y < 0 ? 0 &- y : 0
        let iw = s32(m.ld4(img + oWidth)); let ih = s32(m.ld4(img + oHeight))
        var w2 = iw; var h2 = ih
        if flags & Raster.SCRN != 0 { x = x &+ m.ld8(tk + oPixL); y = y &+ m.ld8(tk + oPixT) }
        if flags & Raster.NEAREST != 0 {
            let cx = s32(m.ld4(dc + oCurX)); let cy = s32(m.ld4(dc + oCurY))
            let dist = sqr(((x &+ iw) >> 1) &- cx) &+ sqr(((y &+ ih) >> 1) &- cy)
            if dist <= m.ld8(dc + oNearest) { m.st8(dc + oNearest, dist) }
        }
        if flags & Raster.SCRN != 0 {
            if x &+ w1 < 0 { w1 = 0 &- x }
            if x &+ w2 > m.ld8(tk + oPixR) &+ 1 { w2 = m.ld8(tk + oPixR) &+ 1 &- x }
            if y &+ h1 < 0 { h1 = 0 &- y }
            if y &+ h2 > m.ld8(tk + oPixB) &+ 1 { h2 = m.ld8(tk + oPixB) &+ 1 &- y }
        }
        let dw = s32(m.ld4(dc + oWidth)); let dh = s32(m.ld4(dc + oHeight))
        if x &+ w2 > dw { w2 = dw &- x }
        if y &+ h2 > dh { h2 = dh &- y }
        if !(w1 < w2 && w2 <= iw && h1 < h2 && h2 <= ih) { return 0 }
        if flags & Raster.EXTENTS != 0 { extents(dc, x &+ w1, x &+ w2 &- 1, y &+ h1, y &+ h2 &- 1) }
        if flags & Raster.DONT_DRAW != 0 { return 1 }
        let noTrans0 = m.ld4(img + oFlags) & Raster.NO_TRANSPARENTS != 0
        // The word-aligned DCF_NO_TRANSPARENTS copies keep TempleOS's exact
        // alignment behaviour by running the original HolyC.
        if noTrans0 && (color0rop(dc) != Raster.ROP_COLLISION) { return try k.callHolyC("GrBlot_HC", dc0, x0, y0, img0) }
        let oldColor = m.ld4(dc + oColor)
        let db = m.ld8(dc + oDb)
        m.st8(dc + oDb, 0)
        let color = oldColor & ~Int64(0x40000000) // ROPF_DITHER cleared
        m.st4(dc + oColor, color)
        let rop0 = Int((color >> 8) & 0xFF)
        let iwi = i32(m.ld4(img + oWI)); let dwi = i32(m.ld4(dc + oWI))
        let ibody = m.ld8(img + oBody); let dbody = m.ld8(dc + oBody)
        let rows = i32(h2 &- h1); let cols = i32(w2 &- w1)
        // (as in Kotlin, a fault here leaves depth_buf/color modified: the try starts below)
        let src0 = try m.checkRows(ibody &+ h1 &* Int64(iwi) &+ w1, Int64(iwi), Int64(rows), Int64(cols))
        let dst0 = try m.checkRows(dbody &+ (y &+ h1) &* Int64(dwi) &+ x &+ w1, Int64(dwi), Int64(rows), Int64(cols))
        let noTrans = m.ld4(img + oFlags) & Raster.NO_TRANSPARENTS != 0
        defer {
            m.st8(dc + oDb, db)
            m.st4(dc + oColor, oldColor)
        }
        let p = m.ptr(0)
        switch rop0 {
        case 2: // ROP_COLLISION
            let bk = m.ld4(dc + oBk) & 0xFF
            var cnt: Int64 = 0
            for r in 0..<max(rows, 0) {
                for i in 0..<max(cols, 0) {
                    let c = Int64(p[dst0 + r * dwi + i])
                    if c != 0xFF && c != bk && p[src0 + r * iwi + i] != 0xFF { cnt += 1 }
                }
            }
            m.st8(dc + oCollision, m.ld8(dc + oCollision) &+ cnt)
        case 3: // ROP_MONO
            let cm = UInt8(truncatingIfNeeded: color & 0xFF)
            if noTrans {
                for r in 0..<max(rows, 0) {
                    for i in 0..<max(cols, 0) { p[dst0 + r * dwi + i] = p[src0 + r * iwi + i] & cm }
                }
            } else {
                for r in 0..<max(rows, 0) {
                    for i in 0..<max(cols, 0) where p[src0 + r * iwi + i] != 0 {
                        try k.gfx.plot0(Int64(dc), x &+ w1 &+ Int64(i), y &+ h1 &+ Int64(r))
                    }
                }
            }
        default: // ROPB_EQU and ROPB_XOR
            if noTrans {
                let isXor = rop0 == Raster.ROP_XOR
                for r in 0..<max(rows, 0) {
                    for i in 0..<max(cols, 0) {
                        let s = p[src0 + r * iwi + i]; let dp = dst0 + r * dwi + i
                        p[dp] = isXor ? p[dp] ^ s : s
                    }
                }
            } else {
                let gfx: Gfx = k.gfx
                for r in 0..<max(rows, 0) {
                    for i in 0..<max(cols, 0) {
                        let c = Int64(p[src0 + r * iwi + i])
                        if c != 0xFF {
                            m.st4(dc + oColor, (color & ~Int64(0xFF)) | c)
                            try gfx.plot0(Int64(dc), x &+ w1 &+ Int64(i), y &+ h1 &+ Int64(r))
                        }
                    }
                }
            }
        }
        return 1
    }

    // ---------------------------------------------------------------- GrFillTri0

    /**
     * Port of GrFillTri0 (Adam/Gr/GrPrimatives.HC). TempleOS has two mirrored
     * halves (scanlines via GrHLine, or columns via GrVLine); [vMajor]=true is
     * the first: u = x (span axis), v = y (iteration axis).
     */
    public func fillTri0(_ dc0: Int64, _ pa: Int64, _ pb: Int64, _ pc: Int64) throws -> Int64 {
        let dc = try dcp(dc0)
        let p = [try readPt(pa), try readPt(pb), try readPt(pc)]
        let x1 = p[0][0], y1 = p[0][1]
        let ay = kabs(y1 &- p[1][1]) &+ kabs(y1 &- p[2][1])
        let ax = kabs(x1 &- p[1][0]) &+ kabs(x1 &- p[2][0])
        return ay <= ax ? try tri(dc, p, 0, 1, true) : try tri(dc, p, 1, 0, false)
    }

    private func readPt(_ a: Int64) throws -> [Int64] {
        let q = try m.check(a, 12)
        return [s32(m.ld4(q)), s32(m.ld4(q + 4)), s32(m.ld4(q + 8))]
    }

    @inline(__always) private func hi(_ v: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: v >> 32)) }

    private func div(_ a: Int64, _ b: Int64) throws -> Int64 {
        if b == 0 { throw VmFault(Vm.DIV_ZERO, "division by zero") }
        return b == -1 ? 0 &- a : a / b
    }

    /** The `draw` local function of Kotlin tri(). */
    @inline(__always) private func triDraw(_ dcl: Int64, _ hmode: Bool, _ u1: Int64, _ u2: Int64, _ v: Int64, _ z1: Int64, _ z2: Int64) throws -> Int64 {
        return hmode ? try hline(dcl, hi(u1), hi(u2), v, hi(z1), hi(z2)) : try vline(dcl, v, hi(u1), hi(u2), hi(z1), hi(z2))
    }

    private func tri(_ dc: Int, _ pts: [[Int64]], _ U: Int, _ V: Int, _ hmode: Bool) throws -> Int64 {
        var p1 = pts[0]; var p2 = pts[1]; var p4 = pts[2]
        if p4[U] < p2[U] { let t = p4; p4 = p2; p2 = t }
        if p2[U] < p1[U] { let t = p2; p2 = p1; p1 = t }
        if p4[V] < p2[V] { let t = p4; p4 = p2; p2 = t }
        var min: Int64 = 0
        var max: Int64 = hmode ? s32(m.ld4(dc + oHeight)) : s32(m.ld4(dc + oWidth))
        if m.ld4(dc + oFlags) & Raster.SCRN != 0 {
            let t = try m.check(m.ld8(dc + oWinTask), 8)
            let off = hmode ? m.ld8(t + oSY) &+ m.ld8(t + oPixT) : m.ld8(t + oSX) &+ m.ld8(t + oPixL)
            min = min &- off; max = max &- off
            let lim = (hmode ? m.ld8(t + oPixB) : m.ld8(t + oPixR)) &- off
            if max > lim { max = lim }
        }
        let dcl = Int64(dc)
        var res: Int64 = 0
        var du1: Int64 = 0, dz1: Int64 = 0, du2: Int64 = 0, dz2: Int64 = 0
        var u1: Int64 = 0, u2: Int64 = 0, v1: Int64 = 0, z1: Int64 = 0, z2: Int64 = 0
        var dv1: Int64 = 0, dv2: Int64 = 0, i: Int64 = 0
        dv2 = p4[V] &- p1[V]
        if dv2 < 0 {
            dv1 = p2[V] &- p1[V]
            du1 = try div((p1[U] &- p2[U]) &<< 32, dv1); dz1 = try div((p1[2] &- p2[2]) &<< 32, dv1)
            du2 = try div((p1[U] &- p4[U]) &<< 32, dv2); dz2 = try div((p1[2] &- p4[2]) &<< 32, dv2)
            u1 = p1[U] &<< 32; u2 = u1; v1 = p1[V]; z1 = p1[2] &<< 32; z2 = z1
            if v1 &+ dv2 < min { i = min &- (v1 &+ dv2); if i > 0 &- dv2 { return res }; dv2 = dv2 &+ i }
            if v1 >= max {
                i = v1 &- max &+ 1; if i > 0 &- dv2 { i = 0 &- dv2 }
                dv2 = dv2 &+ i; v1 = v1 &- i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
            }
            while postInc(&dv2) != 0 { res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2)); v1 = v1 &- 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2 }
            dv2 = p2[V] &- p4[V]
            if dv2 != 0 {
                du2 = try div((p4[U] &- p2[U]) &<< 32, dv2); dz2 = try div((p4[2] &- p2[2]) &<< 32, dv2)
                if v1 &+ dv2 < min { i = min &- (v1 &+ dv2); if i > 0 &- dv2 { return res }; dv2 = dv2 &+ i }
                if v1 >= max {
                    i = v1 &- max &+ 1; if i > 0 &- dv2 { return res }
                    dv2 = dv2 &+ i; v1 = v1 &- i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
                }
            }
            while postInc(&dv2) <= 0 { res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2)); v1 = v1 &- 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2 }
        } else {
            dv2 = p2[V] &- p1[V]
            if dv2 > 0 {
                dv1 = p4[V] &- p1[V]
                du1 = try div((p4[U] &- p1[U]) &<< 32, dv1); dz1 = try div((p4[2] &- p1[2]) &<< 32, dv1)
                du2 = try div((p2[U] &- p1[U]) &<< 32, dv2); dz2 = try div((p2[2] &- p1[2]) &<< 32, dv2)
                u1 = p1[U] &<< 32; u2 = u1; v1 = p1[V]; z1 = p1[2] &<< 32; z2 = z1
                if v1 &+ dv2 >= max { i = v1 &+ dv2 &- max &+ 1; if i > dv2 { return res }; dv2 = dv2 &- i }
                if v1 < min {
                    i = min &- v1; if i > dv2 { i = dv2 }
                    dv2 = dv2 &- i; v1 = v1 &+ i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
                }
                while postDec(&dv2) != 0 { res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2)); v1 = v1 &+ 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2 }
                dv2 = p4[V] &- p2[V]
                if dv2 != 0 {
                    du2 = try div((p4[U] &- p2[U]) &<< 32, dv2); dz2 = try div((p4[2] &- p2[2]) &<< 32, dv2)
                    if v1 &+ dv2 >= max { i = v1 &+ dv2 &- max &+ 1; if i > dv2 { return res }; dv2 = dv2 &- i }
                    if v1 < min {
                        i = min &- v1; if i > dv2 { return res }
                        dv2 = dv2 &- i; v1 = v1 &+ i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
                    }
                }
                while postDec(&dv2) >= 0 { res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2)); v1 = v1 &+ 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2 }
            } else {
                dv1 = p2[V] &- p1[V]
                if dv1 != 0 {
                    du1 = try div((p2[U] &- p1[U]) &<< 32, dv1); dz1 = try div((p2[2] &- p1[2]) &<< 32, dv1)
                    dv2 = p2[V] &- p4[V]
                    if dv2 != 0 { du2 = try div((p2[U] &- p4[U]) &<< 32, dv2); dz2 = try div((p2[2] &- p4[2]) &<< 32, dv2) }
                    else { du2 = 0; dz2 = 0 }
                    u1 = p2[U] &<< 32; u2 = u1; v1 = p2[V]; z1 = p2[2] &<< 32; z2 = z1
                    if v1 < min {
                        i = min &- v1; if i > 0 &- dv1 { i = 0 &- dv1 }
                        dv1 = dv1 &+ i; v1 = v1 &+ i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
                    }
                    while postInc(&dv1) <= 0 {
                        // v1 only grows: past max nothing more is drawn (huge dv1 spun ~2^32 times)
                        if v1 >= max { break }
                        res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2))
                        v1 = v1 &+ 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2
                    }
                }
                dv1 = p4[V] &- p1[V]
                if dv1 != 0 {
                    du1 = try div((p1[U] &- p4[U]) &<< 32, dv1); dz1 = try div((p1[2] &- p4[2]) &<< 32, dv1)
                    dv2 = p4[V] &- p2[V]
                    if dv2 != 0 { du2 = try div((p2[U] &- p4[U]) &<< 32, dv2); dz2 = try div((p2[2] &- p4[2]) &<< 32, dv2) }
                    else { du2 = 0; dz2 = 0 }
                    u1 = p4[U] &<< 32; u2 = u1; v1 = p4[V]; z1 = p4[2] &<< 32; z2 = z1
                    if v1 &- dv1 < min { i = min &- (v1 &- dv1); if i > dv1 { return res }; dv1 = dv1 &- i }
                    if v1 >= max {
                        i = v1 &- max &+ 1; if i > dv1 { return res }
                        dv1 = dv1 &- i; v1 = v1 &- i; u1 = u1 &+ du1 &* i; u2 = u2 &+ du2 &* i; z1 = z1 &+ dz1 &* i; z2 = z2 &+ dz2 &* i
                    }
                    while postDec(&dv1) >= 0 { res = res &+ (try triDraw(dcl, hmode, u1, u2, v1, z1, z2)); v1 = v1 &- 1; u1 = u1 &+ du1; u2 = u2 &+ du2; z1 = z1 &+ dz1; z2 = z2 &+ dz2 }
                }
            }
        }
        return res
    }

    // ---------------------------------------------------------------- transforms

    private var scratchAddr = 0
    /** Kotlin `private val scratch: Int by lazy { m.calloc(24) }`. */
    private func scratch() throws -> Int {
        if scratchAddr == 0 { scratchAddr = try m.calloc(24) }
        return scratchAddr
    }

    /** Mat4x4MulXYZ on raw values (GrDC.HC). */
    public func mulXYZ(_ r: Int, _ v: inout [Int64]) {
        let x = v[0]; let y = v[1]; let z = v[2]
        v[0] = (m.ld8(r) &* x &+ m.ld8(r + 8) &* y &+ m.ld8(r + 16) &* z &+ m.ld8(r + 24)) >> 32
        v[1] = (m.ld8(r + 32) &* x &+ m.ld8(r + 40) &* y &+ m.ld8(r + 48) &* z &+ m.ld8(r + 56)) >> 32
        v[2] = (m.ld8(r + 64) &* x &+ m.ld8(r + 72) &* y &+ m.ld8(r + 80) &* z &+ m.ld8(r + 88)) >> 32
    }

    /**
     * Native Mat4x4MulMat4x4Equ (Adam/Gr/GrMath.HC): dst = m1 x m2 in 32.32 fixed point. Same F64 sums
     * in the same i, j, k order as the original, each element stored as soon as it is computed (so a
     * dst that is also m1 or m2 gives the original's result), converted as HolyC converts F64 to I64.
     */
    public func mulMat4x4(_ dst: Int64, _ m1: Int64, _ m2: Int64) throws -> Int64 {
        let d = try m.check(dst, 128), a = try m.check(m1, 128), b = try m.check(m2, 128)
        for i in 0..<4 {
            for j in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += Double(m.ld8(a + 8 * (k + 4 * j))) * Double(m.ld8(b + 8 * (i + 4 * k))) }
                m.st8(d + 8 * (i + 4 * j), f2i(sum / Raster.GR_SCALE_F))
            }
        }
        return dst
    }

    /**
     * Native DCLighting (Adam/Gr/GrDC.HC), the default dc->lighting: the triangle's normal (scaled to
     * 65536) dotted with dc->ls picks two colors and a dither probability. Every step converts as the
     * HolyC does: differences stored in CD3I32 (I32), I64 products, `vn*=d` through F64, U32 color.
     */
    public func lighting(_ dc0: Int64, _ p1: Int64, _ p2: Int64, _ p3: Int64, _ color0: Int64) throws {
        let dc = try m.check(dc0, 8) // no gr.dc default: the original faults on a NULL dc
        let a = try m.check(p1, 12), b = try m.check(p2, 12), c = try m.check(p3, 12)
        func w(_ at: Int) -> Int64 { s32(m.ld4(at)) }
        let v1x = s32(w(a) &- w(b)), v1y = s32(w(a + 4) &- w(b + 4)), v1z = s32(w(a + 8) &- w(b + 8))
        let v2x = s32(w(c) &- w(b)), v2y = s32(w(c + 4) &- w(b + 4)), v2z = s32(w(c + 8) &- w(b + 8))
        var vnX = v1y &* v2z &- v1z &* v2y
        var vnY = v1z &* v2x &- v1x &* v2z
        var vnZ = v1x &* v2y &- v1y &* v2x
        var d = (Double(vnX &* vnX &+ vnY &* vnY &+ vnZ &* vnZ)).squareRoot()
        if d != 0 { d = 65536.0 / d } // HolyC: 1<<16/d is (1<<16)/d
        vnX = f2i(Double(vnX) * d); vnY = f2i(Double(vnY) * d); vnZ = f2i(Double(vnZ) * d)
        var i = (vnX &* w(dc + oLs) &+ vnY &* w(dc + oLs + 4) &+ vnZ &* w(dc + oLs + 8)) >> 16
        var color = color0 & 0xFFFF_FFFF
        if (color >> 8) & Raster.ROPBF_TWO_SIDED != 0 {
            color &= ~(Raster.ROPBF_TWO_SIDED << 8)
            i = kabs(i) << 1
        } else { i = i &+ 65536 }
        if (color >> 8) & Raster.ROPBF_HALF_RANGE_COLOR != 0 {
            color &= ~(Raster.ROPBF_HALF_RANGE_COLOR << 8)
            i = i >> 1
            if color >= 8 { color -= 8; i = i &+ 65536 }
        }
        if i < 65536 {
            m.st4(dc + oColor, Raster.ROPF_PROBABILITY_DITHER &+ (color << 16))
            m.st8(dc + oDither, i)
        } else {
            m.st4(dc + oColor, Raster.ROPF_PROBABILITY_DITHER &+ ((color ^ 8) << 16) &+ color)
            m.st8(dc + oDither, i &- 65536)
        }
    }

    /** Native DCTransform: rotate by dc->r and translate by dc->x,y,z. */
    public func dcTransform(_ dc: Int, _ v: inout [Int64]) throws {
        mulXYZ(try m.check(m.ld8(dc + oR), 128), &v)
        v[0] = v[0] &+ s32(m.ld4(dc + oDX)); v[1] = v[1] &+ s32(m.ld4(dc + oDY)); v[2] = v[2] &+ s32(m.ld4(dc + oDZ))
    }

    /** (*dc->transform)(dc,&x,&y,&z) - native when it is the default DCTransform. */
    public func transform(_ dc: Int, _ v: inout [Int64]) throws {
        let fp = m.ld8(dc + oTransform)
        if fp == dcTransformPtr { try dcTransform(dc, &v); return }
        let sc = try scratch()
        m.st8(sc, v[0]); m.st8(sc + 8, v[1]); m.st8(sc + 16, v[2])
        _ = try k.vm.callFunction(k.current!, fp, Int64(dc), Int64(sc), Int64(sc + 8), Int64(sc + 16))
        v[0] = m.ld8(sc); v[1] = m.ld8(sc + 8); v[2] = m.ld8(sc + 16)
    }

    private var dcTransformPtrCache: Int64?
    /** Kotlin `val dcTransformPtr: Long by lazy { ... }`. */
    public var dcTransformPtr: Int64 {
        if let v = dcTransformPtrCache { return v }
        let v = k.prog.funcPtr(k.prog.globals["DCTransform"] as! FuncSym)
        dcTransformPtrCache = v
        return v
    }

    /** Port of DCReflect (Adam/Gr/GrMath.HC): reflect a point about dc->sym. */
    public func dcReflect(_ dc: Int, _ v: inout [Int64]) {
        let sx = s32(m.ld4(dc + oSym)); let sy = s32(m.ld4(dc + oSym + 4)); let sz = s32(m.ld4(dc + oSym + 8))
        let snx = m.ld8(dc + oSym + 16); let sny = m.ld8(dc + oSym + 24); let snz = m.ld8(dc + oSym + 32)
        let x = v[0] &<< 32; let y = v[1] &<< 32; let z = v[2] &<< 32
        var xx = v[0] &- sx; var yy = v[1] &- sy; var zz = v[2] &- sz
        let d = (xx &* snx &+ yy &* sny &+ zz &* snz) >> 16
        let xn = d &* (snx >> 15); let yn = d &* (sny >> 15); let zn = d &* (snz >> 15) // HolyC: >> binds tighter than *
        xx = x &- xn; yy = y &- yn; zz = z &- zn
        let xx2 = x &+ xn; let yy2 = y &+ yn; let zz2 = z &+ zn
        let sx16 = sx &<< 16, sy16 = sy &<< 16, sz16 = sz &<< 16
        if sqr((xx >> 16) &- sx16) &+ sqr((yy >> 16) &- sy16) &+ sqr((zz >> 16) &- sz16) <
            sqr((xx2 >> 16) &- sx16) &+ sqr((yy2 >> 16) &- sy16) &+ sqr((zz2 >> 16) &- sz16) {
            v[0] = hi(xx); v[1] = hi(yy); v[2] = hi(zz)
        } else { v[0] = hi(xx2); v[1] = hi(yy2); v[2] = hi(zz2) }
    }

    // ---------------------------------------------------------------- GrBlot3

    /**
     * Port of GrBlot3 (GrPrimatives.HC), including symmetry: the mirrored image is stepped first from
     * the reflected corners, then (unless DCF_JUST_MIRROR) the normal one. With symmetry on, the normal
     * image also takes the stepped path, as in the original (it used to fall back to GrBlot3_HC: 60% of
     * BlackDiamond's and 31% of RawHide's VM time).
     */
    public func blot3(_ dc0: Int64, _ x1a: Int64, _ y1a: Int64, _ z1a: Int64, _ img0: Int64) throws -> Int64 {
        let dc = try dcp(dc0)
        let db0 = m.ld8(dc + oDb)
        if db0 == 0 && m.ld4(dc + oFlags) & 0x300 == 0 { return try blot(Int64(dc), x1a, y1a, img0) }
        let img = try m.check(img0, 8)
        let w = s32(m.ld4(img + oWidth)); let h = s32(m.ld4(img + oHeight))
        let oldColor = m.ld4(dc + oColor)
        let oldBrush = m.ld8(dc + oBrush)
        var p1: [Int64] = [x1a, y1a, z1a]; var p2: [Int64] = [x1a &+ w, y1a, z1a]; var p3: [Int64] = [x1a, y1a &+ h, z1a]
        if m.ld4(dc + oFlags) & 0x100 != 0 { try transform(dc, &p1); try transform(dc, &p2); try transform(dc, &p3) }
        defer {
            m.st4(dc + oColor, oldColor)
            m.st8(dc + oBrush, oldBrush)
        }
        var res: Int64 = 0
        if m.ld4(dc + oFlags) & 0x200 != 0 {
            var q1 = p1, q2 = p2, q3 = p3
            dcReflect(dc, &q1); dcReflect(dc, &q2); dcReflect(dc, &q3)
            if try blot3Steps(dc, img, w, h, q1, q2, q3, oldColor) { res = 1 }
            if m.ld4(dc + oFlags) & 0x400 != 0 { return res } // DCF_JUST_MIRROR
        }
        if try blot3Steps(dc, img, w, h, p1, p2, p3, oldColor) { res = 1 }
        return res
    }

    /** GrBlot3's stepping loop over the image corners [p1] (origin), [p2] (+w), [p3] (+h); false when a side is empty. */
    private func blot3Steps(_ dc: Int, _ img: Int, _ w: Int64, _ h: Int64, _ p1: [Int64], _ p2: [Int64], _ p3: [Int64], _ oldColor: Int64) throws -> Bool {
        var dx1 = p2[0] &- p1[0]; var dy1 = p2[1] &- p1[1]; var dz1 = p2[2] &- p1[2]
        var dx2 = p3[0] &- p1[0]; var dy2 = p3[1] &- p1[1]; var dz2 = p3[2] &- p1[2]
        var d1 = maxAbs(dx1, dy1, dz1); var d2 = maxAbs(dx2, dy2, dz2)
        if kabs(d1) != w || kabs(d2) != h { d1 = d1 &<< 1; d2 = d2 &<< 1 }
        if d1 == 0 || d2 == 0 { return false }
        dx1 = sdiv(dx1 &<< 32, d1); dy1 = sdiv(dy1 &<< 32, d1); dz1 = sdiv(dz1 &<< 32, d1)
        dx2 = sdiv(dx2 &<< 32, d2); dy2 = sdiv(dy2 &<< 32, d2); dz2 = sdiv(dz2 &<< 32, d2)
        m.st8(dc + oBrush, 0)
        var x: Int64 = 0
        let dw = sdiv(w &<< 32, d1); let dh = sdiv(h &<< 32, d2)
        var first = true
        var lastX: Int64 = 0; var lastY: Int64 = 0
        var x1 = p1[0] &<< 32; var y1 = p1[1] &<< 32; var z1 = p1[2] &<< 32
        let mono = Int((oldColor >> 8) & 0xFF) == Raster.ROP_MONO
        // The geometry GrPeek and GrPlot/GrPlot1 read per pixel does not change in this loop (the brush is
        // NULL, plot0 writes only pixels, depth, collision count and extents): read it once. Same pixels as
        // calling peek() and plot()/plot1() per pixel (RasterDiffTests.testBlot3).
        let src = try geom(img), dst = try geom(dc)
        let srcWi = s32(m.ld4(img + oWI)), srcBody = m.ld8(img + oBody)
        if d1 >= 0 {
            for _ in 0...d1 {
                try poll()
                var x2 = x1; var y2 = y1; var z2 = z1
                var y: Int64 = 0
                if d2 >= 0 {
                    for _ in 0...d2 {
                        try poll() // a program-written image height can be huge: Stop must still work
                        if hi(x2) != lastX || hi(y2) != lastY || first {
                            var color: Int64 = -1
                            let px = hi(x) &+ src.dx, py = hi(y) &+ src.dy
                            if src.inside(px, py) { color = m.ld1(try m.check(srcBody &+ srcWi &* py &+ px, 1)) }
                            if color >= 0 {
                                let draw = mono ? color != 0 : color != 0xFF
                                if draw {
                                    m.st4(dc + oColor, mono ? oldColor & ~Int64(0x40000000) : (oldColor & ~Int64(0xFFFF00FF)) | color)
                                    let depth = m.ld8(dc + oDb) != 0
                                    if depth { m.st8(dc + oDbZ, hi(z2)) }
                                    try poll()
                                    let qx = hi(x2) &+ dst.dx, qy = hi(y2) &+ dst.dy
                                    if dst.inside(qx, qy) {
                                        if depth { try k.gfx.plot0(Int64(dc), qx, qy) }
                                        else {
                                            // GrPlot: the depth buffer is off for this pixel
                                            let db = m.ld8(dc + oDb)
                                            if db != 0 { m.st8(dc + oDb, 0) }
                                            defer { if db != 0 { m.st8(dc + oDb, db) } }
                                            try k.gfx.plot0(Int64(dc), qx, qy)
                                        }
                                    }
                                }
                            }
                        }
                        first = false
                        lastX = hi(x2); lastY = hi(y2)
                        x2 = x2 &+ dx2; y2 = y2 &+ dy2; z2 = z2 &+ dz2
                        y = y &+ dh
                    }
                }
                x1 = x1 &+ dx1; y1 = y1 &+ dy1; z1 = z1 &+ dz1
                x = x &+ dw
            }
        }
        return true
    }

    /** A DC's clip geometry as GrPeek/GrPlot1 read it (window offset and bounds for screen DCs), read once. */
    private struct Geom {
        let dx: Int64, dy: Int64, w: Int64, h: Int64, scrn: Bool, l: Int64, r: Int64, t: Int64, b: Int64
        @inline(__always) func inside(_ x: Int64, _ y: Int64) -> Bool {
            if scrn && (x < l || x > r || y < t || y > b) { return false }
            return x >= 0 && x < w && y >= 0 && y < h
        }
    }

    private func geom(_ dc: Int) throws -> Geom {
        let scrn = m.ld4(dc + oFlags) & Raster.SCRN != 0
        let w = s32(m.ld4(dc + oWidth)), h = s32(m.ld4(dc + oHeight))
        if !scrn { return Geom(dx: 0, dy: 0, w: w, h: h, scrn: false, l: 0, r: 0, t: 0, b: 0) }
        let t = try m.check(m.ld8(dc + oWinTask), 8)
        return Geom(dx: m.ld8(t + oPixL) &+ m.ld8(t + oSX), dy: m.ld8(t + oPixT) &+ m.ld8(t + oSY), w: w, h: h, scrn: true,
                    l: m.ld8(t + oPixL), r: m.ld8(t + oPixR), t: m.ld8(t + oPixT), b: m.ld8(t + oPixB))
    }

    private func maxAbs(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
        let aa = kabs(a); let ab = kabs(b); let ac = kabs(c)
        if aa >= ab { return aa >= ac ? aa : ac } else { return ab >= ac ? ab : ac }
    }

    // ---------------------------------------------------------------- fat lines & filled circles

    @inline(__always) private func circleLo(_ d: Int64, _ i: Int64) -> Int64 {
        Int64(Int8(truncatingIfNeeded: m.ld1(o.grAddr + oCircleLo + i32(d &* 64 &+ i))))
    }
    @inline(__always) private func circleHi(_ d: Int64, _ i: Int64) -> Int64 {
        Int64(Int8(truncatingIfNeeded: m.ld1(o.grAddr + oCircleHi + i32(d &* 64 &+ i))))
    }
    private func isqrt(_ v: Int64) -> Int64 { f2i(Double(v).squareRoot()) }

    /** Port of GrFillCircle. */
    public func fillCircle(_ dc: Int64, _ cx: Int64, _ cy: Int64, _ z: Int64, _ diameter: Int64) throws -> Int64 {
        var res: Int64 = 0
        let r = diameter >> 1
        if diameter >= 1 {
            if diameter < 64 {
                var i: Int64 = 0
                while i < diameter {
                    res = res &+ (try hline(dc, circleLo(diameter, i) &+ cx, circleHi(diameter, i) &+ cx, cy &+ i &- r, z, z))
                    i &+= 1
                }
            } else {
                let k1 = diameter &+ 1
                let rr = sqr((k1 &+ 1) >> 1)
                var i: Int64 = 0
                let fcx = Double(cx)
                // TempleOS adds in F64 then truncates: -Sqrt(..)+cx
                while i <= r { let q = Double(rr &- sqr(r &- i)).squareRoot(); res = res &+ (try hline(dc, f2i(-q + fcx), f2i(q + fcx), cy &+ i &- r, z, z)); i &+= 1 }
                while i < k1 { let q = Double(rr &- sqr(i &- r)).squareRoot(); res = res &+ (try hline(dc, f2i(-q + fcx), f2i(q + fcx), cy &+ i &- r, z, z)); i &+= 1 }
            }
        }
        return res
    }

    /** Port of GrFillSemiCircle (n = which half/orientation, 0..7). */
    public func fillSemiCircle(_ dc: Int64, _ cx: Int64, _ cy: Int64, _ z: Int64, _ diameter: Int64, _ n: Int64) throws -> Int64 {
        var res: Int64 = 0
        let r = diameter >> 1
        if diameter < 1 { return 0 }
        let horiz = n == 0 || n == 1 || n == 4 || n == 5
        let upper = n == 0 || n == 2 || n == 4 || n == 6
        let k1 = diameter &+ 1
        let rr = sqr((k1 &+ 1) >> 1)
        let from: Int64 = upper ? 0 : r &+ 1
        let to: Int64 = upper ? r : (diameter < 64 ? diameter : k1)
        var i = from
        while i < to {
            let c = horiz ? cx : cy
            let lo: Int64; let hiV: Int64
            if diameter < 64 { lo = circleLo(diameter, i) &+ c; hiV = circleHi(diameter, i) &+ c }
            else { let q = Double(rr &- sqr(upper ? r &- i : i &- r)).squareRoot(); lo = f2i(-q + Double(c)); hiV = f2i(q + Double(c)) }
            res = res &+ (horiz ? try hline(dc, lo, hiV, cy &+ i &- r, z, z) : try vline(dc, cx &+ i &- r, lo, hiV, z, z))
            i &+= 1
        }
        return res
    }

    /** Port of GrLineFat3 (fixed-point thick line). */
    public func lineFat3(_ dc: Int64, _ x1a: Int64, _ y1a: Int64, _ z1a: Int64, _ x2: Int64, _ y2: Int64, _ z2: Int64, _ width: Int64, _ start: Int64) throws -> Int64 {
        var res: Int64 = 0
        var dx = x2 &- x1a; var dy = y2 &- y1a; var dz = z2 &- z1a
        let adx = kabs(dx); let ady = kabs(dy); let adz = kabs(dz)
        var d: Int64 = 0
        if width <= 0 { return 0 }
        var x1 = x1a; var y1 = y1a; var z1 = z1a
        let one: Int64 = 0x100000000
        if adx >= ady {
            if adx >= adz {
                d = adx
                if d != 0 { dx = dx >= 0 ? one : -one; dy = sdiv(dy &<< 32, d); dz = sdiv(dz &<< 32, d) }
            } else {
                d = adz
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = sdiv(dy &<< 32, d); dz = dz >= 0 ? one : -one }
            }
            x1 = x1 &<< 32; y1 = y1 &<< 32; z1 = z1 &<< 32
            var j: Int64 = 0
            if start > 0 { x1 = x1 &+ dx &* start; y1 = y1 &+ dy &* start; z1 = z1 &+ dz &* start; j = start } // == start additions (mod 2^64)
            if start >= d { res = res &+ (try fillCircle(dc, hi(x1), hi(y1), hi(z1), width)) }
            else if width == 1 {
                var i = start
                while i <= d {
                    m.st8(try dcp(dc) + oDbZ, hi(z1)); res = res &+ (try plot1(dc, hi(x1), hi(y1)))
                    x1 = x1 &+ dx; y1 = y1 &+ dy; z1 = z1 &+ dz; i &+= 1
                }
            } else {
                let ii = f2i(Double(width) * Double(sqr(adx) &+ sqr(ady)).squareRoot() / Double(adx))
                let dLo = ii >> 1; let dHi = (ii &- 1) >> 1
                res = res &+ (try fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, dx >= 0 ? 2 : 7))
                var i = start
                while i <= d {
                    res = res &+ (try vline(dc, hi(x1), hi(y1) &- dLo, hi(y1) &+ dHi, hi(z1), hi(z1)))
                    x1 = x1 &+ dx; y1 = y1 &+ dy; z1 = z1 &+ dz; i &+= 1
                }
                x1 = x1 &- dx; y1 = y1 &- dy; z1 = z1 &- dz
                res = res &+ (try fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, dx >= 0 ? 3 : 6))
            }
        } else {
            if ady >= adz {
                d = ady
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = dy >= 0 ? one : -one; dz = sdiv(dz &<< 32, d) }
            } else {
                d = adz
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = sdiv(dy &<< 32, d); dz = dz >= 0 ? one : -one }
            }
            x1 = x1 &<< 32; y1 = y1 &<< 32; z1 = z1 &<< 32
            var j: Int64 = 0
            if start > 0 { x1 = x1 &+ dx &* start; y1 = y1 &+ dy &* start; z1 = z1 &+ dz &* start; j = start } // == start additions (mod 2^64)
            if start >= d { res = res &+ (try fillCircle(dc, hi(x1), hi(y1), hi(z1), width)) }
            else if width == 1 {
                var i = start
                while i <= d {
                    m.st8(try dcp(dc) + oDbZ, hi(z1)); res = res &+ (try plot1(dc, hi(x1), hi(y1)))
                    x1 = x1 &+ dx; y1 = y1 &+ dy; z1 = z1 &+ dz; i &+= 1
                }
            } else {
                let ii = f2i(Double(width) * Double(sqr(ady) &+ sqr(adx)).squareRoot() / Double(ady))
                let dLo = ii >> 1; let dHi = (ii &- 1) >> 1
                res = res &+ (try fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, dy >= 0 ? 0 : 5))
                var i = start
                while i <= d {
                    res = res &+ (try hline(dc, hi(x1) &- dLo, hi(x1) &+ dHi, hi(y1), hi(z1), hi(z1)))
                    x1 = x1 &+ dx; y1 = y1 &+ dy; z1 = z1 &+ dz; i &+= 1
                }
                x1 = x1 &- dx; y1 = y1 &- dy; z1 = z1 &- dz
                res = res &+ (try fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, dy >= 0 ? 1 : 4))
            }
        }
        return res
    }

    // ---------------------------------------------------------------- Circle (Adam/Gr/GrMath.HC)

    /**
     * Native Circle (Adam/Gr/GrMath.HC): steps the arc with an 8.24 fixed-point rotation and calls
     * [fp] per point, as the original does (GrCircle, GrCircle3 and programs pass their plot callbacks).
     * Same F64 and I64 steps: `1<<GR_SCALE1_BITS*Cos(t)` is (1<<24)*Cos(t) in HolyC, `cx+x>>8` is cx+(x>>8).
     */
    public func circle(_ t: HTask, _ aux: Int64, _ cx: Int64, _ cy: Int64, _ cz: Int64, _ radius: Int64, _ fp: Int64, _ step0: Int64, _ startRad: Double, _ lenRad: Double) throws -> Int64 {
        let len = f2i(ceil(lenRad * Double(radius)))
        if radius <= 0 || step0 == 0 { return 1 }
        var step = step0
        let tt = 1.0 / Double(radius)
        let one = Double(Int64(1) << 24)
        let c = f2i(one * FdLibm.cos(tt))
        let s1: Int64, s2: Int64
        if step < 0 { step = 0 &- step; s2 = f2i(one * FdLibm.sin(tt)); s1 = 0 &- s2 }
        else { s1 = f2i(one * FdLibm.sin(tt)); s2 = 0 &- s1 }
        var x: Int64, y: Int64
        if startRad != 0 { x = f2i(Double(radius) * FdLibm.cos(startRad)); y = f2i(Double(0 &- radius) * FdLibm.sin(startRad)) }
        else { x = radius; y = 0 }
        x = x &<< 8; y = y &<< 8
        var i: Int64 = 0
        while i <= len {
            try poll()
            if try k.vm.callFunction(t, fp, aux, cx &+ (x >> 8), cy &+ (y >> 8), cz) == 0 { return 0 }
            var j: Int64 = 0
            while j < step {
                try poll() // a huge step must not make Stop unresponsive
                let x1 = (c &* x &+ s1 &* y) >> 24
                let y1 = (s2 &* x &+ c &* y) >> 24
                x = x1; y = y1
                j += 1
            }
            i = i &+ step
        }
        return 1
    }

    // ---------------------------------------------------------------- Line (Adam/Gr/GrMath.HC)

    /**
     * Line: steps through a 3D segment in 32.32 fixed point, calling
     * [fp] (aux, x, y, z) for each new point; FALSE from the callback stops.
     */
    public func line(_ t: HTask, _ aux: Int64, _ x1i: Int64, _ y1i: Int64, _ z1i: Int64, _ x2: Int64, _ y2: Int64, _ z2: Int64, _ fp: Int64, _ step: Int64, _ start: Int64) throws -> Int64 {
        var dx = x2 &- x1i; var dy = y2 &- y1i; var dz = z2 &- z1i
        let adx = kabs(dx); let ady = kabs(dy); let adz = kabs(dz)
        var d: Int64 = 0
        let one: Int64 = 0x100000000
        if adx >= ady {
            if adx >= adz {
                d = adx
                if d != 0 { dx = dx >= 0 ? one : -one; dy = sdiv(dy &<< 32, d); dz = sdiv(dz &<< 32, d) }
            } else {
                d = adz
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = sdiv(dy &<< 32, d); dz = dz >= 0 ? one : -one }
            }
        } else {
            if ady >= adz {
                d = ady
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = dy >= 0 ? one : -one; dz = sdiv(dz &<< 32, d) }
            } else {
                d = adz
                if d != 0 { dx = sdiv(dx &<< 32, d); dy = sdiv(dy &<< 32, d); dz = dz >= 0 ? one : -one }
            }
        }
        var x1 = x1i &<< 32; var y1 = y1i &<< 32; var z1 = z1i &<< 32
        var j: Int64 = 0
        if start > 0 { x1 = x1 &+ dx &* start; y1 = y1 &+ dy &* start; z1 = z1 &+ dz &* start; j = start } // == start additions (mod 2^64)
        if step != 1 && step != 0 { dx = dx &* step; dy = dy &* step; dz = dz &* step; d = sdiv(d, step) }
        var px: Int64 = 0; var py: Int64 = 0; var pz: Int64 = 0
        var first = true
        var i = start
        let vm: Vm = k.vm
        while i <= d {
            try poll()
            let cx = s32(x1 >> 32); let cy = s32(y1 >> 32); let cz = s32(z1 >> 32)
            if px != cx || py != cy || pz != cz || first {
                if try vm.callFunction(t, fp, aux, cx, cy, cz) == 0 { return 0 }
            }
            first = false
            px = cx; py = cy; pz = cz
            x1 = x1 &+ dx; y1 = y1 &+ dy; z1 = z1 &+ dz
            i &+= 1
        }
        if step == 1 && (first || px != x2 || py != y2 || pz != z2) {
            if try vm.callFunction(t, fp, aux, x2, y2, z2) == 0 { return 0 }
        }
        return 1
    }

    // MARK: - sprites (Adam/Gr/SpriteNew.HC)

    private var spriteOffsetsReady = false
    private var oStart = 0, oNum = 0, oNpNum = 0, oSt = 0, oWidth2 = 0, oHeight2 = 0
    private var oMuV = 0, oMuT = 0, oPmuV = 0, oPmuT = 0
    private var szD2: Int64 = 0, szD3: Int64 = 0, szTri: Int64 = 0, baseSizes: Int64 = 0

    private func spriteOffsets() {
        if spriteOffsetsReady { return }
        oStart = o.member("CSprite", "start"); oNum = o.member("CSpriteNumU8s", "num")
        oNpNum = o.member("CSpriteNumPtU8s", "num"); oSt = o.member("CSpritePtStr", "st")
        oWidth2 = o.member("CSpritePtWHU8s", "width"); oHeight2 = o.member("CSpritePtWHU8s", "height")
        oMuV = o.member("CSpriteMeshU8s", "vertex_cnt"); oMuT = o.member("CSpriteMeshU8s", "tri_cnt")
        oPmuV = o.member("CSpritePtMeshU8s", "vertex_cnt"); oPmuT = o.member("CSpritePtMeshU8s", "tri_cnt")
        szD2 = Int64(o.cls("CD2I32").size); szD3 = Int64(o.cls("CD3I32").size); szTri = Int64(o.cls("CMeshTri").size)
        baseSizes = Int64((k.prog.globals["sprite_elem_base_sizes"] as! GlobalSym).addr)
        spriteOffsetsReady = true
    }

    private func spI32(_ a: Int64) throws -> Int64 { Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(a, 4)))) }

    /** SpriteElemSize: byte size of the sprite element at [tmpg] (a CSprite*). */
    public func spriteElemSize(_ tmpg: Int64) throws -> Int64 {
        spriteOffsets()
        let e = tmpg &+ Int64(oStart)
        let type = m.ld1(try m.check(e, 1)) & 0x7F
        var i = m.ld8(try m.check(baseSizes &+ type &* 8, 8))
        switch type {
        case 11: i = i &+ (try spI32(e &+ Int64(oNum))) &* szD2                                   // SPT_POLYLINE
        case 27, 28, 29: i = i &+ Int64(try m.strLen(try m.check(e &+ Int64(oSt), 1))) &+ 1   // SPT_TEXT*
        case 23: i = i &+ (((try spI32(e &+ Int64(oWidth2))) &+ 7) & ~7) &* (try spI32(e &+ Int64(oHeight2))) // SPT_BITMAP
        case 9: i = i &+ (((try spI32(e &+ Int64(oNpNum))) &* 3 &+ 7) &>> 3)                    // SPT_POLYPT
        case 17, 18, 19, 20: i = i &+ (try spI32(e &+ Int64(oNum))) &* szD3                     // SPT_BSPLINE*
        case 24: i = i &+ (try spI32(e &+ Int64(oMuV))) &* szD3 &+ (try spI32(e &+ Int64(oMuT))) &* szTri   // SPT_MESH
        case 25: i = i &+ (try spI32(e &+ Int64(oPmuV))) &* szD3 &+ (try spI32(e &+ Int64(oPmuT))) &* szTri // SPT_SHIFTABLE_MESH
        default: break
        }
        return i
    }

    /** SpriteSize: walk the elements and return the size of the sprite as binary data. */
    public func spriteSize(_ elems: Int64) throws -> Int64 {
        spriteOffsets()
        let tmpg1 = elems &- Int64(oStart)
        var tmpg = tmpg1
        // an element type >= SPT_TYPES_NUM (30) ends the sprite, as in the generated library (SpriteTypeOk)
        while true {
            let ty = m.ld1(try m.check(tmpg &+ Int64(oStart), 1)) & 0x7F
            if ty == 0 || ty >= 30 { break }
            if k.vm.interrupt { throw VmKill("stopped") }
            let n = try spriteElemSize(tmpg)
            // a non-positive size never terminates in the HolyC original; fail instead of hanging
            if n <= 0 { throw VmFault(Arena.BAD_MEM, "SpriteSize: invalid sprite element") }
            tmpg = tmpg &+ n
        }
        return tmpg &- tmpg1 &+ m.ld8(try m.check(baseSizes, 8))
    }
}
