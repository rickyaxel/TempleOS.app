package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*

/**
 * Native graphics layer of a kernel: the per-pixel primitive (GrPlot0, a port of
 * TempleOS Adam/Gr/GrBitMap.HC), the text layer, and screen composition.
 * Everything above GrPlot0 is the original TempleOS HolyC graphics library.
 */
class Gfx(private val k: Kernel) {
    private val m get() = k.mem
    private val o get() = k.o

    // CDC member offsets
    private val oWidth = o.dc("width")
    private val oWI = o.dc("width_internal")
    private val oHeight = o.dc("height")
    private val oFlags = o.dc("flags")
    private val oColor = o.dc("color")
    private val oBk = o.dc("bkcolor")
    private val oBody = o.dc("body")
    private val oDb = o.dc("depth_buf")
    private val oDbZ = o.dc("db_z")
    private val oCurX = o.dc("cur_x")
    private val oCurY = o.dc("cur_y")
    private val oNearest = o.dc("nearest_dist")
    private val oMinX = o.dc("min_x")
    private val oMaxX = o.dc("max_x")
    private val oMinY = o.dc("min_y")
    private val oMaxY = o.dc("max_y")
    private val oCollision = o.dc("collision_cnt")
    private val oDither = o.dc("dither_probability_u16")
    private val oSig = o.dc("dc_signature")

    private val grDcOff = o.member("CGrGlbls", "dc")
    private val grDc2Off = o.member("CGrGlbls", "dc2")
    private val grDc1Off = o.member("CGrGlbls", "dc1")
    private val grTextOff = o.member("CGrGlbls", "text_base")

    var grDc = 0L; private set
    var grDc2 = 0L; private set
    var textBase = 0; private set
    var fontAddr = 0; private set

    companion object {
        const val DCF_LOCATE_NEAREST = 0x800L
        const val DCF_DONT_DRAW = 0x1000L
        const val DCF_RECORD_EXTENTS = 0x10000L
        const val DCF_SCRN_BITMAP = 0x4000L
        val DCS_SIG = chCode("DvCS")
        const val ATTRF_BLINK = 0x10000000L
        const val ATTRF_INVERT = 0x20000000L
        const val ATTRF_SEL = 0x40000000L
        const val ATTRF_UNDERLINE = 0x80000000L
    }

    fun initScreens() {
        val dc = k.callHolyC("DCNew", Kernel.W.toLong(), Kernel.H.toLong(), 0, 0)
        val dc2 = k.callHolyC("DCNew", Kernel.W.toLong(), Kernel.H.toLong(), 0, 0)
        grDc = dc; grDc2 = dc2
        m.fill(m.ld8(dc.toInt() + oBody).toInt(), 0xFF, Kernel.W * Kernel.H)
        m.st8(o.grAddr + grDcOff, dc)
        m.st8(o.grAddr + grDc2Off, dc2)
        m.st8(o.grAddr + grDc1Off, dc2)
        m.st4(dc.toInt() + oFlags, m.ld4(dc.toInt() + oFlags) or DCF_SCRN_BITMAP or 0x20000L) // DCF_ON_TOP
        m.st4(dc2.toInt() + oFlags, m.ld4(dc2.toInt() + oFlags) or DCF_SCRN_BITMAP)
        textBase = m.calloc(80L * 60 * 4)
        m.st8(o.grAddr + grTextOff, textBase.toLong())
        // window z-buffer (one U16 per text cell; all zero = nothing covers the window)
        m.st8(o.grAddr + o.member("CGrGlbls", "win_z_buf"), m.calloc(80L * 60 * 2).toLong())
        val unc = m.malloc(65536 / 8)
        m.fill(unc, 0xFF, 65536 / 8)
        m.st8(o.grAddr + o.member("CGrGlbls", "win_uncovered_bitmap"), unc.toLong())
        m.st8(o.grAddr + o.member("CGrGlbls", "vga_text_cache"), m.calloc(80L * 60 * 2).toLong())
        fontAddr = m.malloc(2048)
        m.writeBytes(fontAddr, k.font)
    }

    // ------------------------------------------------------------ GrPlot0

    private fun dcAddr(dc: Long): Int {
        val a = m.check(if (dc == 0L) grDc else dc, 8)
        return a
    }

    /** Port of TempleOS GrPlot0: 2D, no clipping/transformation/thick. */
    fun plot0(dc0: Long, x: Long, y: Long) {
        val dc = dcAddr(dc0)
        val flags = m.ld4(dc + oFlags)
        if (flags and DCF_LOCATE_NEAREST != 0L) {
            val dx = x - m.ld4(dc + oCurX).toInt(); val dy = y - m.ld4(dc + oCurY).toInt()
            val dist = dx * dx + dy * dy
            if (dist <= m.ld8(dc + oNearest)) m.st8(dc + oNearest, dist)
        }
        if (flags and DCF_RECORD_EXTENTS != 0L) {
            if (x < m.ld8(dc + oMinX)) m.st8(dc + oMinX, x)
            if (x > m.ld8(dc + oMaxX)) m.st8(dc + oMaxX, x)
            if (y < m.ld8(dc + oMinY)) m.st8(dc + oMinY, y)
            if (y > m.ld8(dc + oMaxY)) m.st8(dc + oMaxY, y)
        }
        if (flags and DCF_DONT_DRAW != 0L) return
        val wi = m.ld4(dc + oWI).toInt().toLong()
        val d = wi * y + x
        val db = m.ld8(dc + oDb)
        if (db != 0L) {
            val pa = m.check(db + d * 4, 4)
            val dbz = m.ld8(dc + oDbZ)
            if (dbz in 0..m.ld4(pa).toInt().toLong()) m.st4(pa, dbz) else return
        }
        var color = m.ld4(dc + oColor)
        val c1rop = (color ushr 24) and 0xFF
        if (c1rop and 0xC0 != 0L) {
            var swap: Boolean
            if (c1rop and 0x80 != 0L) {
                swap = (k.nextRand(k.current) and 0xFFFF) < m.ld8(dc + oDither) // GrPlot0: RandU16 of the drawing task
            } else swap = ((x xor y) and 1L) != 0L
            if (swap) {
                // color.c1.rop=color.c0.rop; color.c0=color.c1
                val c0rop = (color ushr 8) and 0xFF
                val c1c = (color ushr 16) and 0xFF
                color = c1c or (c0rop shl 8)
            }
        }
        val body = m.ld8(dc + oBody)
        val dst = m.check(body + d, 1)
        when (((color ushr 8) and 0xFF).toInt()) {
            0, 3 -> m.st1(dst, color and 0xFF)
            2 -> {
                val c = m.ld1(dst)
                if (c != 0xFFL && c != (m.ld4(dc + oBk) and 0xFF)) m.st8(dc + oCollision, m.ld8(dc + oCollision) + 1)
            }
            1 -> m.st1(dst, m.ld1(dst) xor (color and 0xFF))
            else -> m.st1(dst, color and 0xFF)
        }
    }

    private val oColor2 = o.dc("color2")
    private val oWinTask = o.dc("win_task")
    private val oPixL = o.task("pix_left")
    private val oPixR = o.task("pix_right")
    private val oPixT = o.task("pix_top")
    private val oPixB = o.task("pix_bottom")
    private val oTScrollX = o.task("scroll_x")
    private val oTScrollY = o.task("scroll_y")

    /**
     * Native replacement for TempleOS GrFloodFillRay (which needs a 16 MiB work
     * buffer). Fills the 4-connected region of pixels equal to dc->color2 (or not
     * equal to it with DCF_FILL_NOT_COLOR) through GrPlot0, so ROP, dithering
     * and the depth buffer behave as in TempleOS. Returns pixels changed.
     */
    fun floodFillRay(dc0: Long, x0: Long, y0: Long, z: Long): Long {
        val dc = dcAddr(dc0)
        val flags = m.ld4(dc + oFlags)
        val w = m.ld4(dc + oWidth).toInt(); val h = m.ld4(dc + oHeight).toInt()
        val wi = m.ld4(dc + oWI).toInt()
        val body = m.ld8(dc + oBody)
        val target = m.ld4(dc + oColor2) and 0xFF
        val notColor = flags and 0x8000L != 0L
        var x = x0; var y = y0
        var left = 0L; var top = 0L; var right = (w - 1).toLong(); var bottom = (h - 1).toLong()
        if (flags and DCF_SCRN_BITMAP != 0L) {
            val tk = m.check(m.ld8(dc + oWinTask), 8)
            x += m.ld8(tk + oTScrollX) + m.ld8(tk + oPixL)
            y += m.ld8(tk + oTScrollY) + m.ld8(tk + oPixT)
            left = maxOf(left, m.ld8(tk + oPixL)); right = minOf(right, m.ld8(tk + oPixR))
            top = maxOf(top, m.ld8(tk + oPixT)); bottom = minOf(bottom, m.ld8(tk + oPixB))
        }
        if (x < left || x > right || y < top || y > bottom) return 0
        // width/height/width_internal are program-writable: a row must fit in the stride
        if (w <= 0 || h <= 0 || wi < w) m.fault(body)
        val bodyA = m.checkRows(body, wi.toLong(), h.toLong(), w.toLong())
        fun px(xx: Int, yy: Int) = m.ld1(bodyA + yy * wi + xx)
        fun match(xx: Int, yy: Int): Boolean { val c = px(xx, yy); return if (notColor) c != target else c == target }
        val visited = java.util.BitSet(w * h)
        val stack = LongArray(4096); var spt = 0
        var growStack = stack
        fun push(xx: Int, yy: Int) {
            if (spt == growStack.size) growStack = growStack.copyOf(spt * 2)
            growStack[spt++] = (xx.toLong() shl 32) or (yy.toLong() and 0xFFFFFFFFL)
        }
        push(x.toInt(), y.toInt())
        var count = 0L
        val savedDbZ = m.ld8(dc + oDbZ)
        m.st8(dc + oDbZ, z)
        // Plotting in screen coordinates: temporarily clear DCF_SCRN_BITMAP is not
        // needed since plot0 takes screen coordinates.
        val l = left.toInt(); val r = right.toInt(); val t = top.toInt(); val b = bottom.toInt()
        while (spt > 0) {
            val v = growStack[--spt]
            val sx = (v shr 32).toInt(); val sy = v.toInt()
            if (visited[sy * w + sx] || !match(sx, sy)) continue
            var x1 = sx
            while (x1 > l && !visited[sy * w + x1 - 1] && match(x1 - 1, sy)) x1--
            var x2 = sx
            while (x2 < r && !visited[sy * w + x2 + 1] && match(x2 + 1, sy)) x2++
            for (xx in x1..x2) {
                visited[sy * w + xx] = true
                plot0(dc0, xx.toLong(), sy.toLong())
                count++
            }
            for (ny in intArrayOf(sy - 1, sy + 1)) {
                if (ny < t || ny > b) continue
                var xx = x1
                while (xx <= x2) {
                    if (!visited[ny * w + xx] && match(xx, ny)) {
                        push(xx, ny)
                        while (xx <= x2 && !visited[ny * w + xx] && match(xx, ny)) xx++
                    }
                    xx++
                }
            }
        }
        m.st8(dc + oDbZ, savedDbZ)
        return count
    }

    fun peek0(dc0: Long, x: Long, y: Long): Long {
        val dc = dcAddr(dc0)
        val wi = m.ld4(dc + oWI).toInt().toLong()
        return m.ld1(m.check(m.ld8(dc + oBody) + wi * y + x, 1))
    }

    // ------------------------------------------------------------ palette

    fun paletteSet(i: Int, bgr48: Long) {
        if (i !in 0..15) return
        val b = ((bgr48 and 0xFFFF) ushr 8).toInt()
        val g = (((bgr48 ushr 16) and 0xFFFF) ushr 8).toInt()
        val r = (((bgr48 ushr 32) and 0xFFFF) ushr 8).toInt()
        k.palette[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    fun paletteGet(i: Int): Long {
        if (i !in 0..15) return 0
        val c = k.palette[i]
        val r = ((c ushr 16) and 0xFF).toLong(); val g = ((c ushr 8) and 0xFF).toLong(); val b = (c and 0xFF).toLong()
        return (b * 0x101) or ((g * 0x101) shl 16) or ((r * 0x101) shl 32)
    }

    // ------------------------------------------------------------ text layer

    private val oScrollX = o.task("scroll_x")
    private val oScrollY = o.task("scroll_y")
    private val oWinL = o.task("win_left")
    private val oWinR = o.task("win_right")
    private val oWinT = o.task("win_top")
    private val oWinB = o.task("win_bottom")

    /** Resolves text cell coordinates like TempleOS _TEXT_CHAR; returns the cell index or -1. */
    private fun textCell(task0: Long, allowBorder: Boolean, x0: Long, y0: Long): Int {
        val task = if (task0 == 0L) (k.current?.fsAddr?.toLong() ?: return -1) else task0
        val tp = m.check(task, 8)
        var x = (m.ld8(tp + oScrollX) shr 3) + x0
        var y = (m.ld8(tp + oScrollY) shr 3) + y0
        val lo = if (allowBorder) -1L else 0L
        if (x < lo) return -1
        x += m.ld8(tp + oWinL)
        if (x > m.ld8(tp + oWinR) + (if (allowBorder) 1 else 0)) return -1
        if (x < 0 || x >= 80) return -1
        if (y < lo) return -1
        y += m.ld8(tp + oWinT)
        if (y > m.ld8(tp + oWinB) + (if (allowBorder) 1 else 0)) return -1
        if (y < 0 || y >= 60) return -1
        return (y * 80 + x).toInt()
    }

    fun textChar(task: Long, allowBorder: Boolean, x: Long, y: Long, d: Long): Boolean {
        val c = textCell(task, allowBorder, x, y)
        if (c < 0) return false
        m.st4(textBase + c * 4, d)
        return true
    }

    fun textAttr(task: Long, x: Long, y: Long, attr: Long): Boolean {
        val c = textCell(task, false, x, y)
        if (c < 0) return false
        val old = m.ld4(textBase + c * 4)
        m.st4(textBase + c * 4, (old and 0xFF) or (attr and 0xFFFFFF00L))
        return true
    }

    fun copyTextCellsToArena(cells: IntArray) {
        for (i in cells.indices) m.st4(textBase + i * 4, cells[i].toLong())
    }

    fun copyTextCellsFromArena(cells: IntArray) {
        for (i in cells.indices) cells[i] = m.ld4(textBase + i * 4).toInt()
    }

    private val oPanX = o.member("CGrGlbls", "pan_text_x")
    private val oPanY = o.member("CGrGlbls", "pan_text_y")
    private val oHideRow = o.member("CGrGlbls", "hide_row")
    private val oHideCol = o.member("CGrGlbls", "hide_col")
    private val oTextFont = o.member("CTextGlbls", "font")
    private val textGlobal = o.global("text")
    private val fontBuf = ByteArray(256 * 8)

    /**
     * The font of the text layer: TempleOS draws with text.font, which programs replace or edit
     * (Demo/Graphics/CharAnimation.HC animates the space glyph, CharDemo makes its own tiles).
     */
    private fun currentFont(): ByteArray {
        val p = m.ld8(textGlobal + oTextFont)
        return try {
            val a = m.check(p, fontBuf.size)
            for (i in fontBuf.indices) fontBuf[i] = m.ld1(a + i).toByte()
            fontBuf
        } catch (_: VmFault) { k.font }
    }

    /**
     * Renders 80x60 text cells (TempleOS text_base layout) into an indexed frame, as Adam/Gr/GrScrn.HC
     * GrUpdateTextBG and GrUpdateTextFG do: every cell's background, then every glyph (shifted by the
     * cell's own 5-bit x/y offsets in bits 16..25); ATTRF_SEL inverts both colors, ATTRF_INVERT swaps
     * them, ATTRF_BLINK swaps them while Blink() (2.5 Hz) is on; gr.pan_text_x/y (-7..7) move the whole
     * layer by pixels and, with gr.hide_col/hide_row, give up one column/row, blanking the edge strips.
     */
    fun renderText(cells: IntArray, frame: ByteArray) {
        val font = currentFont()
        val blink = (k.jiffies() * 5 / 1000) and 1L != 0L // Kernel/KMisc.HC Blink(2.5)
        val gr = o.grAddr
        val panX = m.ld8(gr + oPanX).coerceIn(-7L, 7L).toInt(); m.st8(gr + oPanX, panX.toLong())
        val panY = m.ld8(gr + oPanY).coerceIn(-7L, 7L).toInt(); m.st8(gr + oPanY, panY.toLong())
        val hideCol = m.ld1(gr + oHideCol) != 0L; val hideRow = m.ld1(gr + oHideRow) != 0L
        var numCols = 80; var numRows = 60; var srcCol = 0; var srcRow = 0; var x0 = 0; var y0 = 0
        if (panX != 0 || hideCol) {
            val j = Math.abs(panX) / 8 + 1
            numCols -= j
            if (panX < 0) { srcCol = j; x0 = 8 * j + panX } else x0 = panX
        }
        if (panY != 0 || hideRow) {
            val j = Math.abs(panY) / 8 + 1
            numRows -= j
            if (panY < 0) { srcRow = j; y0 = 8 * j + panY } else y0 = panY
        }
        if (numCols != 80 || numRows != 60) java.util.Arrays.fill(frame, 0) // the blanked edge strips
        val w = Kernel.W; val h = Kernel.H
        fun colorOf(cell: Long): Int {
            var c = ((cell ushr 8) and 0xFF).toInt()
            if (cell and ATTRF_SEL != 0L) c = c xor 0xFF
            if (cell and ATTRF_INVERT != 0L) c = ((c shl 4) or (c ushr 4)) and 0xFF
            if (cell and ATTRF_BLINK != 0L && blink) c = ((c shl 4) or (c ushr 4)) and 0xFF
            return c
        }
        // pass 1: backgrounds
        for (row in 0 until numRows) for (col in 0 until numCols) {
            val cell = cells[(srcRow + row) * 80 + srcCol + col].toLong() and 0xFFFFFFFFL
            val bg = ((colorOf(cell) ushr 4) and 15).toByte()
            val bx = x0 + col * 8; val by = y0 + row * 8
            for (r in 0 until 8) {
                val y = by + r
                if (y !in 0 until h) continue
                val p = y * w
                for (c in 0 until 8) { val x = bx + c; if (x in 0 until w) frame[p + x] = bg }
            }
        }
        // pass 2: glyphs
        for (row in 0 until numRows) for (col in 0 until numCols) {
            val cell = cells[(srcRow + row) * 80 + srcCol + col].toLong() and 0xFFFFFFFFL
            val fg = (colorOf(cell) and 15).toByte()
            val ch = (cell and 0xFF).toInt()
            var ox = ((cell ushr 16) and 0x1F).toInt(); if (ox and 0x10 != 0) ox = ox or 0x1F.inv()
            var oy = ((cell ushr 21) and 0x1F).toInt(); if (oy and 0x10 != 0) oy = oy or 0x1F.inv()
            val bx = x0 + col * 8 + ox; val by = y0 + row * 8 + oy
            for (r in 0 until 8) {
                var bits = font[ch * 8 + r].toInt() and 0xFF
                if (r == 7 && cell and ATTRF_UNDERLINE != 0L) bits = 0xFF
                if (bits == 0) continue
                val y = by + r
                if (y !in 0 until h) continue
                val p = y * w
                for (c in 0 until 8) if ((bits ushr c) and 1 != 0) { val x = bx + c; if (x in 0 until w) frame[p + x] = fg }
            }
        }
    }

    // ------------------------------------------------------------ composition

    /**
     * True once anything was drawn on gr.dc, the persistent screen layer (it starts all
     * TRANSPARENT). Programs like ElephantWalk, MouseDemo and SunMoon draw only there.
     */
    /**
     * The text layer was panned or given another font (Demo/Graphics/PanText.HC, CharAnimation.HC):
     * like drawing, that is only visible on the TempleOS screen, not in the console view.
     */
    fun textLayerTouched(): Boolean {
        val gr = o.grAddr
        if (m.ld8(gr + oPanX) != 0L || m.ld8(gr + oPanY) != 0L || m.ld1(gr + oHideCol) != 0L || m.ld1(gr + oHideRow) != 0L) return true
        if (m.ld8(textGlobal + oTextFont) != fontAddr.toLong()) return true
        val f = k.font
        for (i in 0 until minOf(f.size, 256 * 8)) if (m.ld1(fontAddr + i).toByte() != f[i]) return true
        return false
    }

    fun screenTouched(): Boolean {
        val words = m.words
        // gr.dc->body is program-writable: a program that overwrote it (wild writes) has used the screen
        val body = m.ld8(grDc.toInt() + oBody)
        if (body < 0 || body + Kernel.W * Kernel.H > m.size) return true
        val s1 = body.toInt() ushr 3
        for (w in 0 until Kernel.W * Kernel.H / 8) if (words[s1 + w] != -1L) return true
        return false
    }

    private fun bodyOf(dc: Long) = m.ld8(dc.toInt() + oBody).toInt()

    /** Copies a host frame into gr.dc2's body (the draw_it target). */
    fun loadScreen(frame: ByteArray) {
        val dst = bodyOf(grDc2)
        m.check(dst.toLong(), frame.size) // program-writable body pointer (the Swift port checks it too)
        val words = m.words
        var i = 0
        var w = dst ushr 3
        while (i < frame.size) {
            var v = 0L
            for (j in 7 downTo 0) v = (v shl 8) or (frame[i + j].toLong() and 0xFF)
            words[w++] = v
            i += 8
        }
    }

    fun aliasForDraw(t: Task): Long {
        val dc = k.callHolyC("DCAlias", grDc2, t.fsAddr.toLong(), task = t)
        return dc
    }

    fun freeDrawAlias(dc: Long) {
        try { k.callHolyC("DCDel", dc) } catch (_: RuntimeException) {}
    }

    /** gr.dc2 with gr.dc blotted on top (TRANSPARENT skipped) into [out]. */
    /**
     * Composes the screen into [out]; returns false when no pixel changed, so the
     * UI does not convert and upload an identical frame (most programs redraw
     * every frame even when nothing moves).
     */
    fun composeAndPublish(out: ByteArray): Boolean {
        val words = m.words
        val s2 = bodyOf(grDc2) ushr 3
        val s1 = bodyOf(grDc) ushr 3
        var i = 0
        var diff = 0
        val n = Kernel.W * Kernel.H / 8
        for (w in 0 until n) {
            val a = words[s2 + w]
            val b = words[s1 + w]
            if (b == -1L) {
                for (j in 0 until 8) { val v = (a ushr (8 * j)).toByte(); diff = diff or (out[i + j].toInt() xor v.toInt()); out[i + j] = v }
            } else {
                for (j in 0 until 8) {
                    val pb = ((b ushr (8 * j)) and 0xFF).toInt()
                    val v = if (pb == 0xFF) (a ushr (8 * j)).toByte() else pb.toByte()
                    diff = diff or (out[i + j].toInt() xor v.toInt()); out[i + j] = v
                }
            }
            i += 8
        }
        return diff != 0
    }
}
