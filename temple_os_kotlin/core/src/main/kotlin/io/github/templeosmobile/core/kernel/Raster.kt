package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*

/**
 * Native fast paths for the hottest TempleOS graphics primitives (GrPlot,
 * GrPlot1, GrPeek, GrRect, GrHLine, GrVLine, GrBlot). Each reproduces the
 * pixel results, return values, collision counts and random-number usage of
 * the original HolyC in Adam/Gr/GrBitMap.HC and GrPrimatives.HC, which stay
 * compiled as *_HC: rare paths (pen brushes) call them, and the differential
 * test compares both on random inputs.
 */
class Raster(private val k: Kernel) {
    // Long native loops (huge circles, lines, polygons from program-supplied coordinates)
    // must stay stoppable: poll the VM's hard-stop flag every 64Ki primitive steps.
    private var pollCount = 0
    private fun poll() { if ((++pollCount and 0xFFFF) == 0 && k.vm.interrupt) throw VmKill("Stopped.") }

    private val m get() = k.mem
    private val o get() = k.o

    private val oFlags = o.dc("flags"); private val oWidth = o.dc("width"); private val oWI = o.dc("width_internal")
    private val oHeight = o.dc("height"); private val oColor = o.dc("color"); private val oBk = o.dc("bkcolor")
    private val oBody = o.dc("body"); private val oDb = o.dc("depth_buf"); private val oDbZ = o.dc("db_z")
    private val oCurX = o.dc("cur_x"); private val oCurY = o.dc("cur_y"); private val oNearest = o.dc("nearest_dist")
    private val oMinX = o.dc("min_x"); private val oMaxX = o.dc("max_x"); private val oMinY = o.dc("min_y"); private val oMaxY = o.dc("max_y")
    private val oCollision = o.dc("collision_cnt"); private val oDither = o.dc("dither_probability_u16")
    private val oLs = o.dc("ls")
    private val oBrush = o.dc("brush"); private val oWinTask = o.dc("win_task"); private val oSig = o.dc("dc_signature")
    private val oPixL = o.task("pix_left"); private val oPixR = o.task("pix_right")
    private val oPixT = o.task("pix_top"); private val oPixB = o.task("pix_bottom")
    private val oSX = o.task("scroll_x"); private val oSY = o.task("scroll_y"); private val oSZ = o.task("scroll_z")

    companion object {
        const val SCRN = 0x4000L
        const val NEAREST = 0x800L
        const val DONT_DRAW = 0x1000L
        const val EXTENTS = 0x10000L
        const val NO_TRANSPARENTS = 0x100000L
        const val ROP_EQU = 0; const val ROP_XOR = 1; const val ROP_COLLISION = 2; const val ROP_MONO = 3
        const val DITHER = 0x40L; const val PROB_DITHER = 0x80L
        const val ROPBF_HALF_RANGE_COLOR = 0x10L; const val ROPBF_TWO_SIDED = 0x20L
        const val ROPF_PROBABILITY_DITHER = 0x80000000L
        /** GR_SCALE (Prelude.HC: 32.32 fixed point) as the F64 that sum/GR_SCALE divides by. */
        const val GR_SCALE_F = 4294967296.0
    }

    private fun dcp(dc: Long): Int = m.check(if (dc == 0L) k.gfx.grDc else dc, 8)
    private fun color0rop(dc: Int) = ((m.ld4(dc + oColor) ushr 8) and 0xFF).toInt()

    /** Dithering draws from the current task's generator, as GrPlot0's RandU16 does on TempleOS. */
    private fun rand16() = k.nextRand(k.current) and 0xFFFF

    // ---------------------------------------------------------------- GrPlot / GrPlot1 / GrPeek

    /** GrPlot1: clipping, no transformation or thick; db_z already set. */
    fun plot1(dc0: Long, x0: Long, y0: Long): Long {
        poll()
        val dc = dcp(dc0)
        if (m.ld8(dc + oBrush) != 0L) return k.callHolyC("GrPlot1_HC", dc.toLong(), x0, y0)
        var x = x0; var y = y0
        val flags = m.ld4(dc + oFlags)
        val w = m.ld4(dc + oWidth).toInt().toLong(); val h = m.ld4(dc + oHeight).toInt().toLong()
        if (flags and SCRN != 0L) {
            val t = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(t + oPixL) + m.ld8(t + oSX)
            y += m.ld8(t + oPixT) + m.ld8(t + oSY)
            if (x in m.ld8(t + oPixL)..m.ld8(t + oPixR) && y in m.ld8(t + oPixT)..m.ld8(t + oPixB) && x in 0 until w && y in 0 until h)
                k.gfx.plot0(dc.toLong(), x, y)
        } else if (x in 0 until w && y in 0 until h) k.gfx.plot0(dc.toLong(), x, y)
        return 1
    }

    /** GrPlot: like GrPlot1 with the depth buffer disabled. */
    fun plot(dc0: Long, x: Long, y: Long): Long {
        val dc = dcp(dc0)
        if (m.ld8(dc + oBrush) != 0L) return k.callHolyC("GrPlot_HC", dc.toLong(), x, y)
        val db = m.ld8(dc + oDb)
        if (db != 0L) m.st8(dc + oDb, 0)
        try { plot1(dc.toLong(), x, y) } finally { if (db != 0L) m.st8(dc + oDb, db) }
        return 1
    }

    fun peek(dc0: Long, x0: Long, y0: Long): Long {
        val dc = dcp(dc0)
        var x = x0; var y = y0
        val flags = m.ld4(dc + oFlags)
        val w = m.ld4(dc + oWidth).toInt().toLong(); val h = m.ld4(dc + oHeight).toInt().toLong()
        if (flags and SCRN != 0L) {
            val t = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(t + oPixL) + m.ld8(t + oSX)
            y += m.ld8(t + oPixT) + m.ld8(t + oSY)
            if (x !in m.ld8(t + oPixL)..m.ld8(t + oPixR) || y !in m.ld8(t + oPixT)..m.ld8(t + oPixB) || x !in 0 until w || y !in 0 until h) return -1
        } else if (x !in 0 until w || y !in 0 until h) return -1
        val wi = m.ld4(dc + oWI).toInt().toLong()
        return m.ld1(m.check(m.ld8(dc + oBody) + wi * y + x, 1))
    }

    // ---------------------------------------------------------------- GrRect

    fun rect(dc0: Long, x0: Long, y0: Long, w: Long, h: Long): Long {
        poll()
        val dc = dcp(dc0)
        val flags = m.ld4(dc + oFlags)
        var x = x0; var y = y0
        var tk = 0
        if (flags and SCRN != 0L) {
            tk = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(tk + oSX); y += m.ld8(tk + oSY)
        }
        var w1 = if (x < 0) -x else 0L
        var h1 = if (y < 0) -y else 0L
        var w2 = w; var h2 = h
        if (flags and SCRN != 0L) { x += m.ld8(tk + oPixL); y += m.ld8(tk + oPixT) }
        if (flags and NEAREST != 0L) {
            val cx = m.ld4(dc + oCurX).toInt().toLong(); val cy = m.ld4(dc + oCurY).toInt().toLong()
            val dist = if (cx in x..x + w && cy in y..y + h) 0L else sqr((x + w shr 1) - cx) + sqr((y + h shr 1) - cy)
            if (dist <= m.ld8(dc + oNearest)) m.st8(dc + oNearest, dist)
        }
        if (flags and SCRN != 0L) {
            if (x + w1 < 0) w1 = -x
            if (x + w2 > m.ld8(tk + oPixR) + 1) w2 = m.ld8(tk + oPixR) + 1 - x
            if (y + h1 < 0) h1 = -y
            if (y + h2 > m.ld8(tk + oPixB) + 1) h2 = m.ld8(tk + oPixB) + 1 - y
        }
        val dw = m.ld4(dc + oWidth).toInt().toLong(); val dh = m.ld4(dc + oHeight).toInt().toLong()
        if (x + w2 > dw) w2 = dw - x
        if (y + h2 > dh) h2 = dh - y
        if (!(w1 < w2 && w2 <= w && h1 < h2 && h2 <= h)) return 0
        if (flags and EXTENTS != 0L) extents(dc, x + w1, x + w2 - 1, y + h1, y + h2 - 1)
        if (flags and DONT_DRAW != 0L) return 1
        val color = m.ld4(dc + oColor)
        val wi = m.ld4(dc + oWI).toInt().toLong()
        val body = m.ld8(dc + oBody)
        val xs = (x + w1).toInt(); val xe = (x + w2).toInt() // exclusive
        val ys = (y + h1).toInt(); val ye = (y + h2).toInt()
        val n = xe - xs
        val base = m.checkRows(body + wi * ys + xs, wi, (ye - ys).toLong(), n.toLong())
        val c0rop = ((color ushr 8) and 0xFF).toInt()
        val c1rop = (color ushr 24) and 0xFF
        val c0 = color and 0xFF; val c1 = (color ushr 16) and 0xFF
        if (c0rop == ROP_COLLISION) {
            val bk = m.ld4(dc + oBk) and 0xFF
            var cnt = 0L
            for (r in 0 until ye - ys) {
                val row = base + r * wi.toInt()
                for (i in 0 until n) { val c = m.ld1(row + i); if (c != 0xFFL && c != bk) cnt++ }
            }
            m.st8(dc + oCollision, m.ld8(dc + oCollision) + cnt)
            return cnt
        }
        val xor = c0rop == ROP_XOR
        if (c1rop and (DITHER or PROB_DITHER) != 0L) {
            if (c1rop and PROB_DITHER != 0L) {
                val prob = m.ld8(dc + oDither)
                var cur = if (rand16() < prob) c1 else c0
                for (r in 0 until ye - ys) {
                    fillRow(base + r * wi.toInt(), n, cur, xor)
                    cur = if (rand16() < prob) c1 else c0
                }
            } else {
                for (r in 0 until ye - ys) {
                    val row = base + r * wi.toInt()
                    val yy = ys + r
                    for (i in 0 until n) {
                        val c = if (((xs + i) xor yy) and 1 == 0) c0 else c1
                        if (xor) m.st1(row + i, m.ld1(row + i) xor c) else m.st1(row + i, c)
                    }
                }
            }
        } else {
            for (r in 0 until ye - ys) fillRow(base + r * wi.toInt(), n, c0, xor)
        }
        return (ye - ys).toLong() * n
    }

    private fun fillRow(a: Int, n: Int, c: Long, xor: Boolean) {
        if (!xor) m.fill(a, c.toInt(), n)
        else for (i in 0 until n) m.st1(a + i, m.ld1(a + i) xor c)
    }

    private fun sqr(v: Long) = v * v

    private fun extents(dc: Int, x1: Long, x2: Long, y1: Long, y2: Long) {
        if (x1 < m.ld8(dc + oMinX)) m.st8(dc + oMinX, x1)
        if (x2 > m.ld8(dc + oMaxX)) m.st8(dc + oMaxX, x2)
        if (y1 < m.ld8(dc + oMinY)) m.st8(dc + oMinY, y1)
        if (y2 > m.ld8(dc + oMaxY)) m.st8(dc + oMaxY, y2)
    }

    // ---------------------------------------------------------------- GrPutChar (Adam/Gr/GrBitMap.HC)

    private val oTo8Bits = o.member("CGrGlbls", "to_8_bits")
    private val oTo8Colors = o.member("CGrGlbls", "to_8_colors")
    private val oTextFont = o.member("CTextGlbls", "font")
    private val textAddr = o.global("text")

    /**
     * Native GrPutChar: one 8x8 glyph with clipping (2D, no transformation). Every GrPrint goes through it,
     * so status lines cost about 400 VM instructions per character interpreted. Same memory traffic as the
     * original: the glyph row is read as a U16 at the font byte before it when x is not 8-aligned
     * (`*src(U16 *)>>bit_shift`), and the body is read and written as aligned I64 words with the leading and
     * trailing masks (`dc->body+kk1&~7`: HolyC's & binds tighter than +). The window-covered path of the
     * original writes the same pixels here (IsPixCovered0 is FALSE: one window per kernel). Font and the
     * to_8_bits / to_8_colors tables are read from the arena (FontEd and programs may replace text.font).
     */
    fun putChar(dc0: Long, x0: Long, y0: Long, ch0: Long): Long {
        val dc = m.check(dc0, 8)
        val ch = ch0 and 0xFF
        val flags = m.ld4(dc + oFlags)
        var x = x0; var y = y0
        var tk = 0
        if (flags and SCRN != 0L) {
            tk = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(tk + oSX); y += m.ld8(tk + oSY)
        }
        var w1 = if (x < 0) -x else 0L
        var h1 = if (y < 0) -y else 0L
        var w2 = 8L; var h2 = 8L
        if (flags and SCRN != 0L) { x += m.ld8(tk + oPixL); y += m.ld8(tk + oPixT) }
        if (flags and NEAREST != 0L) {
            val dist = sqr(x + (w2 shr 1) - m.ld4(dc + oCurX).toInt().toLong()) + sqr(y + (h2 shr 1) - m.ld4(dc + oCurY).toInt().toLong())
            if (dist <= m.ld8(dc + oNearest)) m.st8(dc + oNearest, dist)
        }
        if (flags and SCRN != 0L) {
            if (x + w1 < 0) w1 = -x
            if (x + w2 > m.ld8(tk + oPixR) + 1) w2 = m.ld8(tk + oPixR) + 1 - x
            if (y + h1 < 0) h1 = -y
            if (y + h2 > m.ld8(tk + oPixB) + 1) h2 = m.ld8(tk + oPixB) + 1 - y
        }
        val dw = m.ld4(dc + oWidth).toInt().toLong(); val dh = m.ld4(dc + oHeight).toInt().toLong()
        if (x + w2 > dw) w2 = dw - x
        if (y + h2 > dh) h2 = dh - y
        if (!(w1 < w2 && w2 <= 8 && h1 < h2 && h2 <= 8)) return 0
        if (flags and EXTENTS != 0L) extents(dc, x + w1, x + w2 - 1, y + h1, y + h2 - 1)
        if (flags and DONT_DRAW != 0L) return 1
        val color = m.ld4(dc + oColor)
        val to8Bits = m.ld8(o.grAddr + oTo8Bits)
        fun to8(i: Long) = m.ld8(m.check(to8Bits + 8 * i, 8))
        var leading = (-(w1 + x)) and 7
        if (leading == 0L) leading = 8
        var leadingMask = to8(0xFFL shr leading.toInt())
        val bitShift = ((-x) and 7).toInt()
        var trailing = (x + w2) and 7
        val trailingMask = to8((0xFFL shl trailing.toInt()) and 0xFF)
        if (leading + trailing > w2 - w1) { leadingMask = leadingMask or trailingMask; trailing = 0 }
        val fontPtr = m.ld8(textAddr + oTextFont) + 8 * ch + h1
        val wi = m.ld4(dc + oWI).toInt().toLong()
        val body = m.ld8(dc + oBody)
        val rop = (color ushr 8) and 0xFF
        if (rop == ROP_COLLISION.toLong()) {
            val bk = m.ld4(dc + oBk) and 0xFF // color=dc->bkcolor.c0.color
            var bit = w1 and 7
            var i = w1
            while (i < w2) {
                var k1 = (h1 + y) * wi + x
                var src = fontPtr
                var j = h2 - h1
                while (j != 0L) {
                    val c = m.ld1(m.check(body + k1 + i, 1))
                    if (c != 0xFFL && c != bk && (m.ld1(m.check(src + (bit shr 3), 1)) ushr (bit and 7).toInt()) and 1L != 0L)
                        m.st8(dc + oCollision, m.ld8(dc + oCollision) + 1)
                    k1 += wi; src++; j--
                }
                i++; bit++
            }
            return 1
        }
        val colorMask = m.ld8(m.check(m.ld8(o.grAddr + oTo8Colors) + 8 * (color and 0xFF), 8))
        var kk1 = (h1 + y) * wi + x + w1
        fun rows(dst0: Long, src0: Long, mask: Long) {
            var dst = dst0; var src = src0
            var j = h2 - h1
            when (rop) {
                ROP_EQU.toLong(), ROP_MONO.toLong() -> while (j != 0L) {
                    val bits = to8((m.ld2(m.check(src, 2)) ushr bitShift) and 0xFF)
                    val a = m.check(dst, 8); val d = m.ld8(a)
                    m.st8(a, (d and mask) or (((colorMask and bits) or (d and bits.inv())) and mask.inv()))
                    src++; dst += wi; j--
                }
                ROP_XOR.toLong() -> if (colorMask != 0L) while (j != 0L) {
                    val bits = to8((m.ld2(m.check(src, 2)) ushr bitShift) and 0xFF)
                    val a = m.check(dst, 8); val d = m.ld8(a)
                    m.st8(a, (d and mask) or ((d xor bits) and mask.inv()))
                    src++; dst += wi; j--
                }
            }
        }
        rows(body + (kk1 and 7L.inv()), if (bitShift != 0) fontPtr - 1 else fontPtr, leadingMask)
        kk1 += 8
        if (trailing != 0L) rows(body + (kk1 and 7L.inv()), if (bitShift != 0) fontPtr else fontPtr + 1, trailingMask)
        return 1
    }

    // ---------------------------------------------------------------- GrHLine / GrVLine

    fun hline(dc0: Long, x1a: Long, x2a: Long, ya: Long, z1a: Long, z2a: Long): Long =
        line1d(dc0, x1a, x2a, ya, z1a, z2a, horizontal = true)

    fun vline(dc0: Long, xa: Long, y1a: Long, y2a: Long, z1a: Long, z2a: Long): Long =
        line1d(dc0, y1a, y2a, xa, z1a, z2a, horizontal = false)

    /** Shared port of GrHLine/GrVLine: [a1]..[a2] along the line, [b] across it. */
    private fun line1d(dc0: Long, a1a: Long, a2a: Long, ba: Long, z1a: Long, z2a: Long, horizontal: Boolean): Long {
        poll()
        val dc = dcp(dc0)
        if (m.ld8(dc + oDb) == 0L) {
            var a1 = a1a; var a2 = a2a
            if (a2 < a1) { val t = a1; a1 = a2; a2 = t }
            return if (horizontal) rect(dc.toLong(), a1, ba, a2 - a1 + 1, 1) else rect(dc.toLong(), ba, a1, 1, a2 - a1 + 1)
        }
        val flags = m.ld4(dc + oFlags)
        var a1 = a1a; var a2 = a2a; var b = ba; var z1 = z1a; var z2 = z2a
        var tk = 0
        if (flags and SCRN != 0L) {
            tk = m.check(m.ld8(dc + oWinTask), 8)
            val sa = m.ld8(tk + if (horizontal) oSX else oSY); val sb = m.ld8(tk + if (horizontal) oSY else oSX)
            a1 += sa; a2 += sa; b += sb
            z1 += m.ld8(tk + oSZ); z2 += m.ld8(tk + oSZ)
        }
        if (flags and EXTENTS != 0L) {
            if (horizontal) { extents(dc, minOf(a1, a2), maxOf(a1, a2), b, b); extentsX(dc, a1, a2) }
            else { extents(dc, b, b, minOf(a1, a2), maxOf(a1, a2)) }
        }
        if (b < 0) return 0
        if (a2 < a1) { var t = a1; a1 = a2; a2 = t; t = z1; z1 = z2; z2 = t }
        if (a2 < 0) return 0
        var i = 0L
        if (a1 < 0) { i = -a1; a1 = 0 }
        var j = 0L
        if (flags and SCRN != 0L) {
            val pa = m.ld8(tk + if (horizontal) oPixL else oPixT)
            val paMax = m.ld8(tk + if (horizontal) oPixR else oPixB)
            a1 += pa; a2 += pa
            if (a1 > paMax) return 0
            if (a2 > paMax) { j = a2 - paMax; a2 = paMax }
            b += m.ld8(tk + if (horizontal) oPixT else oPixL)
            val pbMax = m.ld8(tk + if (horizontal) oPixB else oPixR)
            if (!(b in 0..pbMax) || a2 < 0) return 0
        }
        val dw = m.ld4(dc + oWidth).toInt().toLong(); val dh = m.ld4(dc + oHeight).toInt().toLong()
        val alim = if (horizontal) dw else dh
        val blim = if (horizontal) dh else dw
        if (a1 >= alim || b >= blim) return 0
        val da = a2 + j - (a1 - i)
        val wi = m.ld4(dc + oWI).toInt().toLong()
        val step = if (horizontal) 1L else wi
        var d = if (horizontal) wi * b + a1 else wi * a1 + b
        val db0 = m.ld8(dc + oDb)
        var db = db0 + d * 4
        val dz = if (da != 0L) (z2 - z1 shl 32) / da else 0L
        var z = z1 shl 32
        if (i != 0L) z += i * dz
        if (a2 >= alim) a2 = alim - 1
        if (flags and NEAREST != 0L) {
            val cx = m.ld4(dc + oCurX).toInt().toLong(); val cy = m.ld4(dc + oCurY).toInt().toLong()
            val ca = if (horizontal) cx else cy; val cb = if (horizontal) cy else cx
            var dist = if (ca in a1..a2) 0L else if (ca < a1) sqr(a1 - ca) else sqr(ca - a2)
            dist += sqr(b - cb)
            if (dist <= m.ld8(dc + oNearest)) m.st8(dc + oNearest, dist)
        }
        if (flags and DONT_DRAW != 0L) return 0
        val color = m.ld4(dc + oColor)
        val c1rop = (color ushr 24) and 0xFF
        val rop0 = ((color ushr 8) and 0xFF).toInt()
        var cc0 = color and 0xFF; var cc1 = (color ushr 16) and 0xFF
        val dither = c1rop and (DITHER or PROB_DITHER) != 0L
        val prob = c1rop and PROB_DITHER != 0L
        val dprob = m.ld8(dc + oDither)
        var cur: Long
        if (dither) {
            if (prob) cur = if (rand16() < dprob) cc1 else cc0
            else {
                val px = if (horizontal) a1 else b; val py = if (horizontal) b else a1
                if ((px xor py) and 1L != 0L) { val t = cc0; cc0 = cc1; cc1 = t }
                cur = cc0
            }
        } else cur = cc0
        val bk = m.ld4(dc + oBk) and 0xFF
        val body = m.ld8(dc + oBody)
        var res = 0L
        var a = a1
        var swapState = false
        while (a <= a2) {
            val dbp = m.check(db, 4)
            val zi = (z shr 32).toInt().toLong()
            if (zi >= 0 && zi <= m.ld4(dbp).toInt().toLong()) {
                m.st4(dbp, zi)
                val dst = m.check(body + d, 1)
                when (rop0) {
                    ROP_COLLISION -> { val c2 = m.ld1(dst); if (c2 != 0xFFL && c2 != bk) m.st8(dc + oCollision, m.ld8(dc + oCollision) + 1) }
                    ROP_XOR -> m.st1(dst, m.ld1(dst) xor cur)
                    else -> m.st1(dst, cur)
                }
                res++
            }
            if (dither) {
                if (prob) cur = if (rand16() < dprob) cc1 else cc0
                else { swapState = !swapState; cur = if (swapState) cc1 else cc0 }
            }
            d += step
            a++
            db += step * 4
            z += dz
        }
        return res
    }

    private fun extentsX(dc: Int, a1: Long, a2: Long) {
        // GrHLine records both endpoints separately (already covered by extents()).
    }

    // ---------------------------------------------------------------- GrBlot

    fun blot(dc0: Long, x0: Long, y0: Long, img0: Long): Long {
        val dc = dcp(dc0)
        val img = m.check(img0, 8)
        val flags = m.ld4(dc + oFlags)
        var x = x0; var y = y0
        var tk = 0
        if (flags and SCRN != 0L) {
            tk = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(tk + oSX); y += m.ld8(tk + oSY)
        }
        var w1 = if (x < 0) -x else 0L
        var h1 = if (y < 0) -y else 0L
        val iw = m.ld4(img + oWidth).toInt().toLong(); val ih = m.ld4(img + oHeight).toInt().toLong()
        var w2 = iw; var h2 = ih
        if (flags and SCRN != 0L) { x += m.ld8(tk + oPixL); y += m.ld8(tk + oPixT) }
        if (flags and NEAREST != 0L) {
            val cx = m.ld4(dc + oCurX).toInt().toLong(); val cy = m.ld4(dc + oCurY).toInt().toLong()
            val dist = sqr((x + iw shr 1) - cx) + sqr((y + ih shr 1) - cy)
            if (dist <= m.ld8(dc + oNearest)) m.st8(dc + oNearest, dist)
        }
        if (flags and SCRN != 0L) {
            if (x + w1 < 0) w1 = -x
            if (x + w2 > m.ld8(tk + oPixR) + 1) w2 = m.ld8(tk + oPixR) + 1 - x
            if (y + h1 < 0) h1 = -y
            if (y + h2 > m.ld8(tk + oPixB) + 1) h2 = m.ld8(tk + oPixB) + 1 - y
        }
        val dw = m.ld4(dc + oWidth).toInt().toLong(); val dh = m.ld4(dc + oHeight).toInt().toLong()
        if (x + w2 > dw) w2 = dw - x
        if (y + h2 > dh) h2 = dh - y
        if (!(w1 < w2 && w2 <= iw && h1 < h2 && h2 <= ih)) return 0
        if (flags and EXTENTS != 0L) extents(dc, x + w1, x + w2 - 1, y + h1, y + h2 - 1)
        if (flags and DONT_DRAW != 0L) return 1
        val noTrans0 = m.ld4(img + oFlags) and NO_TRANSPARENTS != 0L
        // The word-aligned DCF_NO_TRANSPARENTS copies keep TempleOS's exact
        // alignment behaviour by running the original HolyC.
        if (noTrans0 && ((color0rop(dc) != ROP_COLLISION))) return k.callHolyC("GrBlot_HC", dc0, x0, y0, img0)
        val oldColor = m.ld4(dc + oColor)
        val db = m.ld8(dc + oDb)
        m.st8(dc + oDb, 0)
        val color = oldColor and 0x40000000L.inv() // ROPF_DITHER cleared
        m.st4(dc + oColor, color)
        val rop0 = ((color ushr 8) and 0xFF).toInt()
        val iwi = m.ld4(img + oWI).toInt(); val dwi = m.ld4(dc + oWI).toInt()
        val ibody = m.ld8(img + oBody); val dbody = m.ld8(dc + oBody)
        val rows = (h2 - h1).toInt(); val cols = (w2 - w1).toInt()
        val src0 = m.checkRows(ibody + h1 * iwi + w1, iwi.toLong(), rows.toLong(), cols.toLong())
        val dst0 = m.checkRows(dbody + (y + h1) * dwi + x + w1, dwi.toLong(), rows.toLong(), cols.toLong())
        val noTrans = m.ld4(img + oFlags) and NO_TRANSPARENTS != 0L
        try {
            when (rop0) {
                ROP_COLLISION -> {
                    val bk = m.ld4(dc + oBk) and 0xFF
                    var cnt = 0L
                    for (r in 0 until rows) for (i in 0 until cols) {
                        val c = m.ld1(dst0 + r * dwi + i)
                        if (c != 0xFFL && c != bk && m.ld1(src0 + r * iwi + i) != 0xFFL) cnt++
                    }
                    m.st8(dc + oCollision, m.ld8(dc + oCollision) + cnt)
                }
                ROP_MONO -> {
                    val cm = color and 0xFF
                    if (noTrans) {
                        for (r in 0 until rows) for (i in 0 until cols)
                            m.st1(dst0 + r * dwi + i, m.ld1(src0 + r * iwi + i) and cm)
                    } else {
                        for (r in 0 until rows) for (i in 0 until cols)
                            if (m.ld1(src0 + r * iwi + i) != 0L) k.gfx.plot0(dc.toLong(), x + w1 + i, y + h1 + r)
                    }
                }
                else -> { // ROPB_EQU and ROPB_XOR
                    if (noTrans) {
                        for (r in 0 until rows) for (i in 0 until cols) {
                            val s = m.ld1(src0 + r * iwi + i); val dp = dst0 + r * dwi + i
                            m.st1(dp, if (rop0 == ROP_XOR) m.ld1(dp) xor s else s)
                        }
                    } else {
                        for (r in 0 until rows) for (i in 0 until cols) {
                            val c = m.ld1(src0 + r * iwi + i)
                            if (c != 0xFFL) {
                                m.st4(dc + oColor, (color and 0xFFL.inv()) or c)
                                k.gfx.plot0(dc.toLong(), x + w1 + i, y + h1 + r)
                            }
                        }
                    }
                }
            }
        } finally {
            m.st8(dc + oDb, db)
            m.st4(dc + oColor, oldColor)
        }
        return 1
    }

    // ---------------------------------------------------------------- GrFillTri0

    /**
     * Port of GrFillTri0 (Adam/Gr/GrPrimatives.HC). TempleOS has two mirrored
     * halves (scanlines via GrHLine, or columns via GrVLine); [vMajor]=true is
     * the first: u = x (span axis), v = y (iteration axis).
     */
    fun fillTri0(dc0: Long, pa: Long, pb: Long, pc: Long): Long {
        val dc = dcp(dc0)
        val p = arrayOf(readPt(pa), readPt(pb), readPt(pc))
        val (x1, y1) = p[0][0] to p[0][1]
        val ay = Math.abs(y1 - p[1][1]) + Math.abs(y1 - p[2][1])
        val ax = Math.abs(x1 - p[1][0]) + Math.abs(x1 - p[2][0])
        return if (ay <= ax) tri(dc, p, 0, 1, true) else tri(dc, p, 1, 0, false)
    }

    private fun readPt(a: Long): LongArray {
        val q = m.check(a, 12)
        return longArrayOf(m.ld4(q).toInt().toLong(), m.ld4(q + 4).toInt().toLong(), m.ld4(q + 8).toInt().toLong())
    }

    private fun hi(v: Long) = (v shr 32).toInt().toLong()

    private fun div(a: Long, b: Long): Long {
        if (b == 0L) throw VmFault(Vm.DIV_ZERO, "division by zero")
        return if (b == -1L) -a else a / b
    }

    private fun tri(dc: Int, pts: Array<LongArray>, U: Int, V: Int, hmode: Boolean): Long {
        var p1 = pts[0]; var p2 = pts[1]; var p4 = pts[2]
        if (p4[U] < p2[U]) { val t = p4; p4 = p2; p2 = t }
        if (p2[U] < p1[U]) { val t = p2; p2 = p1; p1 = t }
        if (p4[V] < p2[V]) { val t = p4; p4 = p2; p2 = t }
        var min = 0L
        var max = if (hmode) m.ld4(dc + oHeight).toInt().toLong() else m.ld4(dc + oWidth).toInt().toLong()
        if (m.ld4(dc + oFlags) and SCRN != 0L) {
            val t = m.check(m.ld8(dc + oWinTask), 8)
            val off = if (hmode) m.ld8(t + oSY) + m.ld8(t + oPixT) else m.ld8(t + oSX) + m.ld8(t + oPixL)
            min -= off; max -= off
            val lim = (if (hmode) m.ld8(t + oPixB) else m.ld8(t + oPixR)) - off
            if (max > lim) max = lim
        }
        val dcl = dc.toLong()
        var res = 0L
        fun draw(u1: Long, u2: Long, v: Long, z1: Long, z2: Long) {
            res += if (hmode) hline(dcl, hi(u1), hi(u2), v, hi(z1), hi(z2)) else vline(dcl, v, hi(u1), hi(u2), hi(z1), hi(z2))
        }
        var du1: Long; var dz1: Long; var du2: Long; var dz2: Long
        var u1: Long; var u2: Long; var v1: Long; var z1: Long; var z2: Long
        var dv1: Long; var dv2: Long; var i: Long
        dv2 = p4[V] - p1[V]
        if (dv2 < 0) {
            dv1 = p2[V] - p1[V]
            du1 = div((p1[U] - p2[U]) shl 32, dv1); dz1 = div((p1[2] - p2[2]) shl 32, dv1)
            du2 = div((p1[U] - p4[U]) shl 32, dv2); dz2 = div((p1[2] - p4[2]) shl 32, dv2)
            u1 = p1[U] shl 32; u2 = u1; v1 = p1[V]; z1 = p1[2] shl 32; z2 = z1
            if (v1 + dv2 < min) { i = min - (v1 + dv2); if (i > -dv2) return res; dv2 += i }
            if (v1 >= max) {
                i = v1 - max + 1; if (i > -dv2) i = -dv2
                dv2 += i; v1 -= i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
            }
            while (dv2++ != 0L) { draw(u1, u2, v1, z1, z2); v1--; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2 }
            dv2 = p2[V] - p4[V]
            if (dv2 != 0L) {
                du2 = div((p4[U] - p2[U]) shl 32, dv2); dz2 = div((p4[2] - p2[2]) shl 32, dv2)
                if (v1 + dv2 < min) { i = min - (v1 + dv2); if (i > -dv2) return res; dv2 += i }
                if (v1 >= max) {
                    i = v1 - max + 1; if (i > -dv2) return res
                    dv2 += i; v1 -= i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
                }
            }
            while (dv2++ <= 0) { draw(u1, u2, v1, z1, z2); v1--; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2 }
        } else {
            dv2 = p2[V] - p1[V]
            if (dv2 > 0) {
                dv1 = p4[V] - p1[V]
                du1 = div((p4[U] - p1[U]) shl 32, dv1); dz1 = div((p4[2] - p1[2]) shl 32, dv1)
                du2 = div((p2[U] - p1[U]) shl 32, dv2); dz2 = div((p2[2] - p1[2]) shl 32, dv2)
                u1 = p1[U] shl 32; u2 = u1; v1 = p1[V]; z1 = p1[2] shl 32; z2 = z1
                if (v1 + dv2 >= max) { i = v1 + dv2 - max + 1; if (i > dv2) return res; dv2 -= i }
                if (v1 < min) {
                    i = min - v1; if (i > dv2) i = dv2
                    dv2 -= i; v1 += i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
                }
                while (dv2-- != 0L) { draw(u1, u2, v1, z1, z2); v1++; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2 }
                dv2 = p4[V] - p2[V]
                if (dv2 != 0L) {
                    du2 = div((p4[U] - p2[U]) shl 32, dv2); dz2 = div((p4[2] - p2[2]) shl 32, dv2)
                    if (v1 + dv2 >= max) { i = v1 + dv2 - max + 1; if (i > dv2) return res; dv2 -= i }
                    if (v1 < min) {
                        i = min - v1; if (i > dv2) return res
                        dv2 -= i; v1 += i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
                    }
                }
                while (dv2-- >= 0) { draw(u1, u2, v1, z1, z2); v1++; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2 }
            } else {
                dv1 = p2[V] - p1[V]
                if (dv1 != 0L) {
                    du1 = div((p2[U] - p1[U]) shl 32, dv1); dz1 = div((p2[2] - p1[2]) shl 32, dv1)
                    dv2 = p2[V] - p4[V]
                    if (dv2 != 0L) { du2 = div((p2[U] - p4[U]) shl 32, dv2); dz2 = div((p2[2] - p4[2]) shl 32, dv2) }
                    else { du2 = 0; dz2 = 0 }
                    u1 = p2[U] shl 32; u2 = u1; v1 = p2[V]; z1 = p2[2] shl 32; z2 = z1
                    if (v1 < min) {
                        i = min - v1; if (i > -dv1) i = -dv1
                        dv1 += i; v1 += i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
                    }
                    while (dv1++ <= 0) {
                        // v1 only grows: past max nothing more is drawn (huge dv1 spun ~2^32 times)
                        if (v1 >= max) break
                        draw(u1, u2, v1, z1, z2)
                        v1++; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2
                    }
                }
                dv1 = p4[V] - p1[V]
                if (dv1 != 0L) {
                    du1 = div((p1[U] - p4[U]) shl 32, dv1); dz1 = div((p1[2] - p4[2]) shl 32, dv1)
                    dv2 = p4[V] - p2[V]
                    if (dv2 != 0L) { du2 = div((p2[U] - p4[U]) shl 32, dv2); dz2 = div((p2[2] - p4[2]) shl 32, dv2) }
                    else { du2 = 0; dz2 = 0 }
                    u1 = p4[U] shl 32; u2 = u1; v1 = p4[V]; z1 = p4[2] shl 32; z2 = z1
                    if (v1 - dv1 < min) { i = min - (v1 - dv1); if (i > dv1) return res; dv1 -= i }
                    if (v1 >= max) {
                        i = v1 - max + 1; if (i > dv1) return res
                        dv1 -= i; v1 -= i; u1 += du1 * i; u2 += du2 * i; z1 += dz1 * i; z2 += dz2 * i
                    }
                    while (dv1-- >= 0) { draw(u1, u2, v1, z1, z2); v1--; u1 += du1; u2 += du2; z1 += dz1; z2 += dz2 }
                }
            }
        }
        return res
    }

    // ---------------------------------------------------------------- transforms

    private val oR = o.dc("r"); private val oDX = o.dc("x"); private val oDY = o.dc("y"); private val oDZ = o.dc("z")
    private val oTransform = o.dc("transform")
    private val oSym = o.dc("sym")
    private val scratch: Int by lazy { m.calloc(24) }

    /** Mat4x4MulXYZ on raw values (GrDC.HC). */
    fun mulXYZ(r: Int, v: LongArray) {
        val x = v[0]; val y = v[1]; val z = v[2]
        v[0] = (m.ld8(r) * x + m.ld8(r + 8) * y + m.ld8(r + 16) * z + m.ld8(r + 24)) shr 32
        v[1] = (m.ld8(r + 32) * x + m.ld8(r + 40) * y + m.ld8(r + 48) * z + m.ld8(r + 56)) shr 32
        v[2] = (m.ld8(r + 64) * x + m.ld8(r + 72) * y + m.ld8(r + 80) * z + m.ld8(r + 88)) shr 32
    }

    /**
     * Native Mat4x4MulMat4x4Equ (Adam/Gr/GrMath.HC): dst = m1 x m2 in 32.32 fixed point. Same F64 sums
     * in the same i, j, k order as the original, each element stored as soon as it is computed (so a
     * dst that is also m1 or m2 gives the original's result), converted as HolyC converts F64 to I64.
     */
    fun mulMat4x4(dst: Long, m1: Long, m2: Long): Long {
        val d = m.check(dst, 128); val a = m.check(m1, 128); val b = m.check(m2, 128)
        for (i in 0 until 4) for (j in 0 until 4) {
            var sum = 0.0
            for (k in 0 until 4) sum += m.ld8(a + 8 * (k + 4 * j)).toDouble() * m.ld8(b + 8 * (i + 4 * k)).toDouble()
            m.st8(d + 8 * (i + 4 * j), f2i(sum / GR_SCALE_F))
        }
        return dst
    }

    /**
     * Native DCLighting (Adam/Gr/GrDC.HC), the default dc->lighting: the triangle's normal (scaled to
     * 65536) dotted with dc->ls picks two colors and a dither probability. Every step converts as the
     * HolyC does: differences stored in CD3I32 (I32), I64 products, `vn*=d` through F64, U32 color.
     */
    fun lighting(dc0: Long, p1: Long, p2: Long, p3: Long, color0: Long) {
        val dc = m.check(dc0, 8) // no gr.dc default: the original faults on a NULL dc
        val a = m.check(p1, 12); val b = m.check(p2, 12); val c = m.check(p3, 12)
        fun i32(at: Int) = m.ld4(at).toInt().toLong()
        val v1x = (i32(a) - i32(b)).toInt().toLong(); val v1y = (i32(a + 4) - i32(b + 4)).toInt().toLong(); val v1z = (i32(a + 8) - i32(b + 8)).toInt().toLong()
        val v2x = (i32(c) - i32(b)).toInt().toLong(); val v2y = (i32(c + 4) - i32(b + 4)).toInt().toLong(); val v2z = (i32(c + 8) - i32(b + 8)).toInt().toLong()
        var vnX = v1y * v2z - v1z * v2y
        var vnY = v1z * v2x - v1x * v2z
        var vnZ = v1x * v2y - v1y * v2x
        var d = Math.sqrt((vnX * vnX + vnY * vnY + vnZ * vnZ).toDouble())
        if (d != 0.0) d = 65536.0 / d // HolyC: 1<<16/d is (1<<16)/d
        vnX = f2i(vnX.toDouble() * d); vnY = f2i(vnY.toDouble() * d); vnZ = f2i(vnZ.toDouble() * d)
        var i = (vnX * i32(dc + oLs) + vnY * i32(dc + oLs + 4) + vnZ * i32(dc + oLs + 8)) shr 16
        var color = color0 and 0xFFFFFFFFL
        if ((color ushr 8) and ROPBF_TWO_SIDED != 0L) {
            color = color and (ROPBF_TWO_SIDED shl 8).inv()
            i = Math.abs(i) shl 1
        } else i += 65536
        if ((color ushr 8) and ROPBF_HALF_RANGE_COLOR != 0L) {
            color = color and (ROPBF_HALF_RANGE_COLOR shl 8).inv()
            i = i shr 1
            if (color >= 8) { color -= 8; i += 65536 }
        }
        if (i < 65536) {
            m.st4(dc + oColor, ROPF_PROBABILITY_DITHER + (color shl 16))
            m.st8(dc + oDither, i)
        } else {
            m.st4(dc + oColor, ROPF_PROBABILITY_DITHER + ((color xor 8) shl 16) + color)
            m.st8(dc + oDither, i - 65536)
        }
    }

    /** Native DCTransform: rotate by dc->r and translate by dc->x,y,z. */
    fun dcTransform(dc: Int, v: LongArray) {
        mulXYZ(m.check(m.ld8(dc + oR), 128), v)
        v[0] += m.ld4(dc + oDX).toInt(); v[1] += m.ld4(dc + oDY).toInt(); v[2] += m.ld4(dc + oDZ).toInt()
    }

    /** (*dc->transform)(dc,&x,&y,&z) - native when it is the default DCTransform. */
    fun transform(dc: Int, v: LongArray) {
        val fp = m.ld8(dc + oTransform)
        if (fp == dcTransformPtr) { dcTransform(dc, v); return }
        val sc = scratch
        m.st8(sc, v[0]); m.st8(sc + 8, v[1]); m.st8(sc + 16, v[2])
        k.vm.callFunction(k.current!!, fp, dc.toLong(), sc.toLong(), sc + 8L, sc + 16L)
        v[0] = m.ld8(sc); v[1] = m.ld8(sc + 8); v[2] = m.ld8(sc + 16)
    }

    val dcTransformPtr: Long by lazy { k.prog.funcPtr(k.prog.globals["DCTransform"] as FuncSym) }

    /** Port of DCReflect (Adam/Gr/GrMath.HC): reflect a point about dc->sym. */
    fun dcReflect(dc: Int, v: LongArray) {
        val sx = m.ld4(dc + oSym).toInt().toLong(); val sy = m.ld4(dc + oSym + 4).toInt().toLong(); val sz = m.ld4(dc + oSym + 8).toInt().toLong()
        val snx = m.ld8(dc + oSym + 16); val sny = m.ld8(dc + oSym + 24); val snz = m.ld8(dc + oSym + 32)
        val x = v[0] shl 32; val y = v[1] shl 32; val z = v[2] shl 32
        var xx = v[0] - sx; var yy = v[1] - sy; var zz = v[2] - sz
        val d = (xx * snx + yy * sny + zz * snz) shr 16
        val xn = d * (snx shr 15); val yn = d * (sny shr 15); val zn = d * (snz shr 15) // HolyC: >> binds tighter than *
        xx = x - xn; yy = y - yn; zz = z - zn
        val xx2 = x + xn; val yy2 = y + yn; val zz2 = z + zn
        if (sqr((xx shr 16) - (sx shl 16)) + sqr((yy shr 16) - (sy shl 16)) + sqr((zz shr 16) - (sz shl 16)) <
            sqr((xx2 shr 16) - (sx shl 16)) + sqr((yy2 shr 16) - (sy shl 16)) + sqr((zz2 shr 16) - (sz shl 16))) {
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
    fun blot3(dc0: Long, x1a: Long, y1a: Long, z1a: Long, img0: Long): Long {
        val dc = dcp(dc0)
        val db0 = m.ld8(dc + oDb)
        if (db0 == 0L && m.ld4(dc + oFlags) and 0x300L == 0L) return blot(dc.toLong(), x1a, y1a, img0)
        val img = m.check(img0, 8)
        val w = m.ld4(img + oWidth).toInt().toLong(); val h = m.ld4(img + oHeight).toInt().toLong()
        val oldColor = m.ld4(dc + oColor)
        val oldBrush = m.ld8(dc + oBrush)
        val p1 = longArrayOf(x1a, y1a, z1a); val p2 = longArrayOf(x1a + w, y1a, z1a); val p3 = longArrayOf(x1a, y1a + h, z1a)
        if (m.ld4(dc + oFlags) and 0x100L != 0L) { transform(dc, p1); transform(dc, p2); transform(dc, p3) }
        var res = 0L
        try {
            if (m.ld4(dc + oFlags) and 0x200L != 0L) {
                val q1 = p1.copyOf(); val q2 = p2.copyOf(); val q3 = p3.copyOf()
                dcReflect(dc, q1); dcReflect(dc, q2); dcReflect(dc, q3)
                if (blot3Steps(dc, img, w, h, q1, q2, q3, oldColor)) res = 1
                if (m.ld4(dc + oFlags) and 0x400L != 0L) return res // DCF_JUST_MIRROR
            }
            if (blot3Steps(dc, img, w, h, p1, p2, p3, oldColor)) res = 1
            return res
        } finally {
            m.st4(dc + oColor, oldColor)
            m.st8(dc + oBrush, oldBrush)
        }
    }

    /** GrBlot3's stepping loop over the image corners [p1] (origin), [p2] (+w), [p3] (+h); false when a side is empty. */
    private fun blot3Steps(dc: Int, img: Int, w: Long, h: Long, p1: LongArray, p2: LongArray, p3: LongArray, oldColor: Long): Boolean {
        var dx1 = p2[0] - p1[0]; var dy1 = p2[1] - p1[1]; var dz1 = p2[2] - p1[2]
        var dx2 = p3[0] - p1[0]; var dy2 = p3[1] - p1[1]; var dz2 = p3[2] - p1[2]
        var d1 = maxAbs(dx1, dy1, dz1); var d2 = maxAbs(dx2, dy2, dz2)
        if (Math.abs(d1) != w || Math.abs(d2) != h) { d1 = d1 shl 1; d2 = d2 shl 1 }
        if (d1 == 0L || d2 == 0L) return false
        dx1 = (dx1 shl 32) / d1; dy1 = (dy1 shl 32) / d1; dz1 = (dz1 shl 32) / d1
        dx2 = (dx2 shl 32) / d2; dy2 = (dy2 shl 32) / d2; dz2 = (dz2 shl 32) / d2
        m.st8(dc + oBrush, 0)
        var x = 0L
        val dw = (w shl 32) / d1; val dh = (h shl 32) / d2
        var first = true
        var lastX = 0L; var lastY = 0L
        var x1 = p1[0] shl 32; var y1 = p1[1] shl 32; var z1 = p1[2] shl 32
        val mono = ((oldColor ushr 8) and 0xFF).toInt() == ROP_MONO
        // The geometry GrPeek and GrPlot/GrPlot1 read per pixel does not change in this loop (the brush is
        // NULL, plot0 writes only pixels, depth, collision count and extents): read it once. Same pixels as
        // calling peek() and plot()/plot1() per pixel (RasterDiffTest.blot3).
        val src = PeekGeom(img); val dst = PlotGeom(dc)
        for (j in 0..d1) {
            poll()
            var x2 = x1; var y2 = y1; var z2 = z1
            var y = 0L
            for (i in 0..d2) {
                poll() // a program-written image height can be huge: Stop must still work
                if (hi(x2) != lastX || hi(y2) != lastY || first) {
                    val color = src.peek(hi(x), hi(y))
                    if (color >= 0) {
                        val draw = if (mono) color != 0L else color != 0xFFL
                        if (draw) {
                            m.st4(dc + oColor, if (mono) oldColor and 0x40000000L.inv() else (oldColor and 0xFFFF00FFL.inv()) or color)
                            if (m.ld8(dc + oDb) != 0L) { m.st8(dc + oDbZ, hi(z2)); dst.plot(hi(x2), hi(y2), true) }
                            else dst.plot(hi(x2), hi(y2), false)
                        }
                    }
                }
                first = false
                lastX = hi(x2); lastY = hi(y2)
                x2 += dx2; y2 += dy2; z2 += dz2
                y += dh
            }
            x1 += dx1; y1 += dy1; z1 += dz1
            x += dw
        }
        return true
    }

    /** GrPeek of one image with its geometry read once (see blot3Steps). */
    private inner class PeekGeom(dc: Int) {
        private val scrn = m.ld4(dc + oFlags) and SCRN != 0L
        private val w = m.ld4(dc + oWidth).toInt().toLong(); private val h = m.ld4(dc + oHeight).toInt().toLong()
        private val wi = m.ld4(dc + oWI).toInt().toLong()
        private val body = m.ld8(dc + oBody)
        private val t = if (scrn) m.check(m.ld8(dc + oWinTask), 8) else 0
        private val dx = if (scrn) m.ld8(t + oPixL) + m.ld8(t + oSX) else 0L
        private val dy = if (scrn) m.ld8(t + oPixT) + m.ld8(t + oSY) else 0L
        private val l = if (scrn) m.ld8(t + oPixL) else 0L; private val r = if (scrn) m.ld8(t + oPixR) else 0L
        private val tp = if (scrn) m.ld8(t + oPixT) else 0L; private val b = if (scrn) m.ld8(t + oPixB) else 0L
        fun peek(x0: Long, y0: Long): Long {
            val x = x0 + dx; val y = y0 + dy
            if (scrn && (x !in l..r || y !in tp..b)) return -1
            if (x !in 0 until w || y !in 0 until h) return -1
            return m.ld1(m.check(body + wi * y + x, 1))
        }
    }

    /** GrPlot1 (depth buffer on) or GrPlot (off) into one DC with its geometry read once (see blot3Steps). */
    private inner class PlotGeom(private val dc: Int) {
        private val scrn = m.ld4(dc + oFlags) and SCRN != 0L
        private val w = m.ld4(dc + oWidth).toInt().toLong(); private val h = m.ld4(dc + oHeight).toInt().toLong()
        private val t = if (scrn) m.check(m.ld8(dc + oWinTask), 8) else 0
        private val dx = if (scrn) m.ld8(t + oPixL) + m.ld8(t + oSX) else 0L
        private val dy = if (scrn) m.ld8(t + oPixT) + m.ld8(t + oSY) else 0L
        private val l = if (scrn) m.ld8(t + oPixL) else 0L; private val r = if (scrn) m.ld8(t + oPixR) else 0L
        private val tp = if (scrn) m.ld8(t + oPixT) else 0L; private val b = if (scrn) m.ld8(t + oPixB) else 0L
        fun plot(x0: Long, y0: Long, depth: Boolean) {
            poll()
            val x = x0 + dx; val y = y0 + dy
            if (scrn && (x !in l..r || y !in tp..b)) return
            if (x !in 0 until w || y !in 0 until h) return
            if (depth) { k.gfx.plot0(dc.toLong(), x, y); return }
            // GrPlot: the depth buffer is off for this pixel
            val db = m.ld8(dc + oDb)
            if (db != 0L) m.st8(dc + oDb, 0)
            try { k.gfx.plot0(dc.toLong(), x, y) } finally { if (db != 0L) m.st8(dc + oDb, db) }
        }
    }

    private fun maxAbs(a: Long, b: Long, c: Long): Long {
        val aa = Math.abs(a); val ab = Math.abs(b); val ac = Math.abs(c)
        return if (aa >= ab) { if (aa >= ac) aa else ac } else { if (ab >= ac) ab else ac }
    }

    // ---------------------------------------------------------------- fat lines & filled circles

    private val oCircleLo = o.member("CGrGlbls", "circle_lo")
    private val oCircleHi = o.member("CGrGlbls", "circle_hi")
    private fun circleLo(d: Long, i: Long) = m.ld1(o.grAddr + oCircleLo + (d * 64 + i).toInt()).toByte().toLong()
    private fun circleHi(d: Long, i: Long) = m.ld1(o.grAddr + oCircleHi + (d * 64 + i).toInt()).toByte().toLong()
    private fun isqrt(v: Long): Long = f2i(Math.sqrt(v.toDouble()))

    /** Port of GrFillCircle. */
    fun fillCircle(dc: Long, cx: Long, cy: Long, z: Long, diameter: Long): Long {
        var res = 0L
        val r = diameter shr 1
        if (diameter >= 1) {
            if (diameter < 64) {
                for (i in 0 until diameter) res += hline(dc, circleLo(diameter, i) + cx, circleHi(diameter, i) + cx, cy + i - r, z, z)
            } else {
                val k1 = diameter + 1
                val rr = sqr((k1 + 1) shr 1)
                var i = 0L
                // TempleOS adds in F64 then truncates: -Sqrt(..)+cx
                while (i <= r) { val q = Math.sqrt((rr - sqr(r - i)).toDouble()); res += hline(dc, f2i(-q + cx), f2i(q + cx), cy + i - r, z, z); i++ }
                while (i < k1) { val q = Math.sqrt((rr - sqr(i - r)).toDouble()); res += hline(dc, f2i(-q + cx), f2i(q + cx), cy + i - r, z, z); i++ }
            }
        }
        return res
    }

    /** Port of GrFillSemiCircle (n = which half/orientation, 0..7). */
    fun fillSemiCircle(dc: Long, cx: Long, cy: Long, z: Long, diameter: Long, n: Long): Long {
        var res = 0L
        val r = diameter shr 1
        if (diameter < 1) return 0
        val horiz = n == 0L || n == 1L || n == 4L || n == 5L
        val upper = n == 0L || n == 2L || n == 4L || n == 6L
        val k1 = diameter + 1
        val rr = sqr((k1 + 1) shr 1)
        val from = if (upper) 0L else r + 1
        val to = if (upper) r else if (diameter < 64) diameter else k1
        var i = from
        while (i < to) {
            val c = if (horiz) cx else cy
            val lo: Long; val hiV: Long
            if (diameter < 64) { lo = circleLo(diameter, i) + c; hiV = circleHi(diameter, i) + c }
            else { val q = Math.sqrt((rr - sqr(if (upper) r - i else i - r)).toDouble()); lo = f2i(-q + c); hiV = f2i(q + c) }
            res += if (horiz) hline(dc, lo, hiV, cy + i - r, z, z) else vline(dc, cx + i - r, lo, hiV, z, z)
            i++
        }
        return res
    }

    /** Port of GrLineFat3 (fixed-point thick line). */
    fun lineFat3(dc: Long, x1a: Long, y1a: Long, z1a: Long, x2: Long, y2: Long, z2: Long, width: Long, start: Long): Long {
        var res = 0L
        var dx = x2 - x1a; var dy = y2 - y1a; var dz = z2 - z1a
        val adx = Math.abs(dx); val ady = Math.abs(dy); val adz = Math.abs(dz)
        var d = 0L
        if (width <= 0) return 0
        var x1 = x1a; var y1 = y1a; var z1 = z1a
        if (adx >= ady) {
            if (adx >= adz) {
                d = adx
                if (d != 0L) { dx = if (dx >= 0) 0x100000000L else -0x100000000L; dy = (dy shl 32) / d; dz = (dz shl 32) / d }
            } else {
                d = adz
                if (d != 0L) { dx = (dx shl 32) / d; dy = (dy shl 32) / d; dz = if (dz >= 0) 0x100000000L else -0x100000000L }
            }
            x1 = x1 shl 32; y1 = y1 shl 32; z1 = z1 shl 32
            if (start > 0) { x1 += dx * start; y1 += dy * start; z1 += dz * start } // == start additions (mod 2^64)
            if (start >= d) res += fillCircle(dc, hi(x1), hi(y1), hi(z1), width)
            else if (width == 1L) {
                var i = start
                while (i <= d) {
                    m.st8(dcp(dc) + oDbZ, hi(z1)); res += plot1(dc, hi(x1), hi(y1))
                    x1 += dx; y1 += dy; z1 += dz; i++
                }
            } else {
                val ii = f2i(width * Math.sqrt((sqr(adx) + sqr(ady)).toDouble()) / adx)
                val dLo = ii shr 1; val dHi = (ii - 1) shr 1
                res += fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, if (dx >= 0) 2 else 7)
                var i = start
                while (i <= d) {
                    res += vline(dc, hi(x1), hi(y1) - dLo, hi(y1) + dHi, hi(z1), hi(z1))
                    x1 += dx; y1 += dy; z1 += dz; i++
                }
                x1 -= dx; y1 -= dy; z1 -= dz
                res += fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, if (dx >= 0) 3 else 6)
            }
        } else {
            if (ady >= adz) {
                d = ady
                if (d != 0L) { dx = (dx shl 32) / d; dy = if (dy >= 0) 0x100000000L else -0x100000000L; dz = (dz shl 32) / d }
            } else {
                d = adz
                if (d != 0L) { dx = (dx shl 32) / d; dy = (dy shl 32) / d; dz = if (dz >= 0) 0x100000000L else -0x100000000L }
            }
            x1 = x1 shl 32; y1 = y1 shl 32; z1 = z1 shl 32
            if (start > 0) { x1 += dx * start; y1 += dy * start; z1 += dz * start } // == start additions (mod 2^64)
            if (start >= d) res += fillCircle(dc, hi(x1), hi(y1), hi(z1), width)
            else if (width == 1L) {
                var i = start
                while (i <= d) {
                    m.st8(dcp(dc) + oDbZ, hi(z1)); res += plot1(dc, hi(x1), hi(y1))
                    x1 += dx; y1 += dy; z1 += dz; i++
                }
            } else {
                val ii = f2i(width * Math.sqrt((sqr(ady) + sqr(adx)).toDouble()) / ady)
                val dLo = ii shr 1; val dHi = (ii - 1) shr 1
                res += fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, if (dy >= 0) 0 else 5)
                var i = start
                while (i <= d) {
                    res += hline(dc, hi(x1) - dLo, hi(x1) + dHi, hi(y1), hi(z1), hi(z1))
                    x1 += dx; y1 += dy; z1 += dz; i++
                }
                x1 -= dx; y1 -= dy; z1 -= dz
                res += fillSemiCircle(dc, hi(x1), hi(y1), hi(z1), width, if (dy >= 0) 1 else 4)
            }
        }
        return res
    }

    // ---------------------------------------------------------------- Line (Adam/Gr/GrMath.HC)

    /**
     * Line: steps through a 3D segment in 32.32 fixed point, calling
     * [fp] (aux, x, y, z) for each new point; FALSE from the callback stops.
     */
    fun line(t: Task, aux: Long, x1i: Long, y1i: Long, z1i: Long, x2: Long, y2: Long, z2: Long, fp: Long, step: Long, start: Long): Long {
        var dx = x2 - x1i; var dy = y2 - y1i; var dz = z2 - z1i
        val adx = Math.abs(dx); val ady = Math.abs(dy); val adz = Math.abs(dz)
        var d = 0L
        val one = 0x100000000L
        if (adx >= ady) {
            if (adx >= adz) {
                d = adx
                if (d != 0L) { dx = if (dx >= 0) one else -one; dy = (dy shl 32) / d; dz = (dz shl 32) / d }
            } else {
                d = adz
                if (d != 0L) { dx = (dx shl 32) / d; dy = (dy shl 32) / d; dz = if (dz >= 0) one else -one }
            }
        } else {
            if (ady >= adz) {
                d = ady
                if (d != 0L) { dx = (dx shl 32) / d; dy = if (dy >= 0) one else -one; dz = (dz shl 32) / d }
            } else {
                d = adz
                if (d != 0L) { dx = (dx shl 32) / d; dy = (dy shl 32) / d; dz = if (dz >= 0) one else -one }
            }
        }
        var x1 = x1i shl 32; var y1 = y1i shl 32; var z1 = z1i shl 32
        var j = 0L
        if (start > 0) { x1 += dx * start; y1 += dy * start; z1 += dz * start; j = start } // == start additions (mod 2^64)
        if (step != 1L && step != 0L) { dx *= step; dy *= step; dz *= step; d /= step }
        var px = 0L; var py = 0L; var pz = 0L
        var first = true
        var i = start
        while (i <= d) {
            poll()
            val cx = (x1 shr 32).toInt().toLong(); val cy = (y1 shr 32).toInt().toLong(); val cz = (z1 shr 32).toInt().toLong()
            if ((px != cx || py != cy || pz != cz || first) && k.vm.callFunction(t, fp, aux, cx, cy, cz) == 0L) return 0
            first = false
            px = cx; py = cy; pz = cz
            x1 += dx; y1 += dy; z1 += dz
            i++
        }
        if (step == 1L && (first || px != x2 || py != y2 || pz != z2) && k.vm.callFunction(t, fp, aux, x2, y2, z2) == 0L) return 0
        return 1
    }

    /**
     * Native Circle (Adam/Gr/GrMath.HC): steps the arc with an 8.24 fixed-point rotation and calls
     * [fp] per point, as the original does (GrCircle, GrCircle3 and programs pass their plot callbacks).
     * Same F64 and I64 steps: `1<<GR_SCALE1_BITS*Cos(t)` is (1<<24)*Cos(t) in HolyC, `cx+x>>8` is cx+(x>>8).
     */
    fun circle(t: Task, aux: Long, cx: Long, cy: Long, cz: Long, radius: Long, fp: Long, step0: Long, startRad: Double, lenRad: Double): Long {
        val len = f2i(Math.ceil(lenRad * radius))
        if (radius <= 0 || step0 == 0L) return 1
        var step = step0
        val tt = 1.0 / radius
        val one = (1L shl 24).toDouble()
        val c = f2i(one * StrictMath.cos(tt))
        val s1: Long; val s2: Long
        if (step < 0) { step = -step; s2 = f2i(one * StrictMath.sin(tt)); s1 = -s2 }
        else { s1 = f2i(one * StrictMath.sin(tt)); s2 = -s1 }
        var x: Long; var y: Long
        if (startRad != 0.0) { x = f2i(radius * StrictMath.cos(startRad)); y = f2i((-radius) * StrictMath.sin(startRad)) }
        else { x = radius; y = 0 }
        x = x shl 8; y = y shl 8
        var i = 0L
        while (i <= len) {
            poll()
            if (k.vm.callFunction(t, fp, aux, cx + (x shr 8), cy + (y shr 8), cz) == 0L) return 0
            for (j in 0 until step) {
                poll() // a huge step must not make Stop unresponsive
                val x1 = (c * x + s1 * y) shr 24
                val y1 = (s2 * x + c * y) shr 24
                x = x1; y = y1
            }
            i += step
        }
        return 1
    }

    // ---------------------------------------------------------------- sprites (Adam/Gr/SpriteNew.HC)

    private val oStart by lazy { o.member("CSprite", "start") }
    private val oNum by lazy { o.member("CSpriteNumU8s", "num") }
    private val oNpNum by lazy { o.member("CSpriteNumPtU8s", "num") }
    private val oSt by lazy { o.member("CSpritePtStr", "st") }
    private val oWidth2 by lazy { o.member("CSpritePtWHU8s", "width") }
    private val oHeight2 by lazy { o.member("CSpritePtWHU8s", "height") }
    private val oMuV by lazy { o.member("CSpriteMeshU8s", "vertex_cnt") }
    private val oMuT by lazy { o.member("CSpriteMeshU8s", "tri_cnt") }
    private val oPmuV by lazy { o.member("CSpritePtMeshU8s", "vertex_cnt") }
    private val oPmuT by lazy { o.member("CSpritePtMeshU8s", "tri_cnt") }
    private val szD2 by lazy { o.cls("CD2I32").size.toLong() }
    private val szD3 by lazy { o.cls("CD3I32").size.toLong() }
    private val szTri by lazy { o.cls("CMeshTri").size.toLong() }
    private val baseSizes by lazy { (k.prog.globals["sprite_elem_base_sizes"] as GlobalSym).addr.toLong() }

    private fun i32(a: Long): Long = m.ld4(m.check(a, 4)).toInt().toLong()

    /** SpriteElemSize: byte size of the sprite element at [tmpg] (a CSprite*). */
    fun spriteElemSize(tmpg: Long): Long {
        val e = tmpg + oStart
        val type = m.ld1(m.check(e, 1)) and 0x7F
        var i = m.ld8(m.check(baseSizes + type * 8, 8))
        when (type.toInt()) {
            11 -> i += i32(e + oNum) * szD2                                        // SPT_POLYLINE
            27, 28, 29 -> i += m.strLen(m.check(e + oSt, 1)) + 1                   // SPT_TEXT*
            23 -> i += ((i32(e + oWidth2) + 7) and 7L.inv()) * i32(e + oHeight2)   // SPT_BITMAP
            9 -> i += (i32(e + oNpNum) * 3 + 7) shr 3                              // SPT_POLYPT
            17, 18, 19, 20 -> i += i32(e + oNum) * szD3                            // SPT_BSPLINE*
            24 -> i += i32(e + oMuV) * szD3 + i32(e + oMuT) * szTri                // SPT_MESH
            25 -> i += i32(e + oPmuV) * szD3 + i32(e + oPmuT) * szTri              // SPT_SHIFTABLE_MESH
        }
        return i
    }

    /** SpriteSize: walk the elements and return the size of the sprite as binary data. */
    fun spriteSize(elems: Long): Long {
        val tmpg1 = elems - oStart
        var tmpg = tmpg1
        // an element type >= SPT_TYPES_NUM (30) ends the sprite, as in the generated library (SpriteTypeOk)
        while ((m.ld1(m.check(tmpg + oStart, 1)) and 0x7F).let { it != 0L && it < 30 }) {
            if (k.vm.interrupt) throw VmKill("stopped")
            val n = spriteElemSize(tmpg)
            // a non-positive size never terminates in the HolyC original; fail instead of hanging
            if (n <= 0) throw VmFault(Arena.BAD_MEM, "SpriteSize: invalid sprite element")
            tmpg += n
        }
        return tmpg - tmpg1 + m.ld8(m.check(baseSizes, 8))
    }
}
