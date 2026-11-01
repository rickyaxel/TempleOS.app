package io.github.templeosmobile.core.ui

import java.text.BreakIterator
import java.util.Locale

/** Rectangle in logical pixels. */
data class Rect(val x: Int, val y: Int, val w: Int, val h: Int) {
    val right get() = x + w
    val bottom get() = y + h
    fun contains(px: Int, py: Int) = px >= x && py >= y && px < x + w && py < y + h
    fun inset(d: Int) = Rect(x + d, y + d, maxOf(0, w - 2 * d), maxOf(0, h - 2 * d))
}

/**
 * The shell's indexed (16-color) framebuffer in logical pixels. One font
 * pixel is one logical pixel; platforms scale by an integer factor with
 * nearest-neighbour sampling.
 */
class Surface(width: Int, height: Int, private val font: ByteArray) {
    data class ToolbarLayout(val buttons: List<Rect>, val trailing: Rect, val height: Int)

    /** Keep natural label widths and move actions/path/status to another row when needed. */
    fun toolbarLayout(labels: List<String>, r: Rect, rowH: Int, trailingMin: Int): ToolbarLayout {
        var x = r.x + 2; var y = r.y
        val buttons = ArrayList<Rect>()
        for (label in labels) {
            val w = minOf(maxOf(8, r.w - 4), measureUi(label) + 8)
            if (x > r.x + 2 && x + w > r.right - 2) { x = r.x + 2; y += rowH }
            buttons.add(Rect(x, y + 1, w, rowH - 2)); x += w + 4
        }
        if (r.right - x < trailingMin) { x = r.x + 2; y += rowH }
        return ToolbarLayout(buttons, Rect(x, y, maxOf(0, r.right - x - 2), rowH), y - r.y + rowH)
    }

    var width = width; private set
    var height = height; private set
    var px = ByteArray(width * height); private set
    /** Incremented when the content changes (platform uploads on change). */
    var version = 0L; private set

    private var clip = Rect(0, 0, width, height)

    fun resize(w: Int, h: Int) {
        if (w == width && h == height) return
        width = w; height = h
        px = ByteArray(w * h)
        clip = Rect(0, 0, w, h)
    }

    fun touch() { version++ }

    // ------------------------------------------------------------ text the TempleOS font cannot show

    /**
     * A string with characters outside the TempleOS font (CJK, Arabic, Devanagari, Cyrillic,
     * most non-Western-European Latin…). The platform draws it with its own text engine at
     * device resolution (shaping, bidi), inside [clip] and outside every [Occluder] with a
     * higher [z]. [x], [y], [w] are logical px; [y] is the top of the 8 px TempleOS text row.
     */
    class TextRun(val x: Int, val y: Int, val w: Int, val text: String, val fg: Int, val rtl: Boolean, val clip: Rect, val z: Int,
                  /** Text magnification, as for TempleOS glyphs ([MenuMetrics.textScale]): 10*scale px on an 8*scale px row. */
                  val scale: Int = 1)

    /** Something drawn opaquely above earlier text runs (a window, menu, dialog, keyboard…). */
    class Occluder(val rect: Rect, val z: Int)

    companion object {
        /**
         * The vertical span (logical px, top to bottom) a text run's ink may use: its clip (the row's box, 2*scale
         * above and below the 8*scale row, cut by its container), less any part covered by something drawn above it
         * that overlaps the run horizontally: a window title's box ends where the window's menu bar starts. The platforms keep
         * the run's ink inside it (moved, or the font made just small enough) so tall scripts are not cut.
         */
        fun runInkBox(r: TextRun, occluders: List<Occluder>): Pair<Int, Int> {
            var top = r.clip.y; var bottom = r.clip.bottom
            val mid = r.y + 4 * r.scale
            for (o in occluders) {
                if (o.z <= r.z || o.rect.right <= r.clip.x || o.rect.x >= r.clip.right) continue
                if (o.rect.y >= mid) bottom = minOf(bottom, o.rect.y)
                else if (o.rect.bottom <= mid) top = maxOf(top, o.rect.bottom)
            }
            return top to maxOf(bottom, top + 1)
        }
    }

    val runs = ArrayList<TextRun>()
    val occluders = ArrayList<Occluder>()
    private var z = 0

    /** Logical-px width of a string drawn by the platform (set by the shell from its env). */
    var measureNative: (String) -> Int = { it.length * 8 }

    /** Clears runs and occluders at the start of a full render. */
    fun beginFrame() { runs.clear(); occluders.clear(); z = 0 }

    /** Starts a new stacking layer; [r] hides the text runs of every earlier layer. */
    fun layer(r: Rect?) { z++; if (r != null) occluders.add(Occluder(r, z)) }

    /** Width of localized UI text in logical px (8 per char in the TempleOS font), magnified by [scale]. */
    fun measureUi(s: String, scale: Int = 1) = if (Cp437.representable(s)) s.length * 8 * scale else measureNative(s) * scale

    /**
     * Draws localized UI text: with the TempleOS font when every character exists in it, else
     * as a [TextRun]. Text wider than [maxW] is cut. With [alignEnd] (right-to-left languages)
     * the text ends at x + maxW. [scale] magnifies each font pixel to scale x scale logical px
     * (menus, MenuMetrics); the row is then 8*scale px high. Returns the x after the text.
     */
    fun uiText(x: Int, y: Int, s: String, fg: Int, maxW: Int = Int.MAX_VALUE, bg: Int = -1, alignEnd: Boolean = false, scale: Int = 1): Int {
        if (s.isEmpty()) return x
        val cw = 8 * scale
        if (Cp437.representable(s)) {
            val enc = Cp437.encode(s)
            val n = if (maxW == Int.MAX_VALUE) enc.length else minOf(enc.length, maxOf(0, maxW / cw))
            val tx = if (alignEnd && maxW != Int.MAX_VALUE) x + maxW - n * cw else x
            for (i in 0 until n) glyph(tx + i * cw, y, enc[i].code, fg, bg, scale = scale)
            return tx + n * cw
        }
        val w = minOf(measureNative(s) * scale, maxW)
        val limit = if (maxW == Int.MAX_VALUE) w else maxW
        if (bg >= 0) fillRect(x, y, limit, cw, bg)
        val c = clip
        val box = Rect(x, y - 2 * scale, limit, 12 * scale)
        val x0 = maxOf(c.x, box.x); val y0 = maxOf(c.y, box.y)
        val x1 = minOf(c.right, box.right); val y1 = minOf(c.bottom, box.bottom)
        if (x1 > x0 && y1 > y0) runs.add(TextRun(x, y, limit, s, fg, alignEnd, Rect(x0, y0, x1 - x0, y1 - y0), z, scale))
        return x + w
    }

    /** Splits [s] into lines no wider than [maxW] at [scale]: at spaces, or anywhere for scripts without them. */
    fun wrapUi(s: String, maxW: Int, scale: Int = 1): List<String> {
        val out = ArrayList<String>()
        for (para in s.split('\n')) {
            var line = StringBuilder()
            for (word in para.split(' ')) {
                val cand = if (line.isEmpty()) word else "$line $word"
                if (measureUi(cand, scale) <= maxW) { line = StringBuilder(cand); continue }
                if (line.isNotEmpty()) { out.add(line.toString()); line = StringBuilder() }
                // A long word or an unspaced script: use logical characters, not UTF-16 units.
                // Keep combining marks, surrogate pairs and joined glyphs in the same shaped run.
                var rest = word
                if (measureUi(rest, scale) > maxW) {
                    val characters = BreakIterator.getCharacterInstance(Locale.ROOT)
                    while (measureUi(rest, scale) > maxW) {
                        characters.setText(rest)
                        val first = characters.following(0)
                        if (first == BreakIterator.DONE || first == rest.length) break
                        var n = characters.preceding(rest.length)
                        while (n > first && measureUi(rest.substring(0, n), scale) > maxW) n = characters.preceding(n)
                        out.add(rest.substring(0, n)); rest = rest.substring(n)
                    }
                }
                line = StringBuilder(rest)
            }
            out.add(line.toString())
        }
        return out
    }

    fun setClip(r: Rect?) {
        clip = if (r == null) Rect(0, 0, width, height) else {
            val x0 = maxOf(0, r.x); val y0 = maxOf(0, r.y)
            val x1 = minOf(width, r.right); val y1 = minOf(height, r.bottom)
            Rect(x0, y0, maxOf(0, x1 - x0), maxOf(0, y1 - y0))
        }
    }

    inline fun withClip(r: Rect, block: () -> Unit) {
        val saved = getClip()
        setClip(r.intersect(saved))
        try { block() } finally { setClip(saved) }
    }

    fun getClip() = clip

    fun plot(x: Int, y: Int, c: Int) {
        if (x < clip.x || y < clip.y || x >= clip.right || y >= clip.bottom) return
        px[y * width + x] = c.toByte()
    }

    fun fill(r: Rect, c: Int) = fillRect(r.x, r.y, r.w, r.h, c)

    fun fillRect(x: Int, y: Int, w: Int, h: Int, c: Int) {
        val x0 = maxOf(x, clip.x); val y0 = maxOf(y, clip.y)
        val x1 = minOf(x + w, clip.right); val y1 = minOf(y + h, clip.bottom)
        if (x0 >= x1 || y0 >= y1) return
        val b = c.toByte()
        for (yy in y0 until y1) java.util.Arrays.fill(px, yy * width + x0, yy * width + x1, b)
    }

    fun hline(x0: Int, x1: Int, y: Int, c: Int) = fillRect(minOf(x0, x1), y, Math.abs(x1 - x0) + 1, 1, c)
    fun vline(x: Int, y0: Int, y1: Int, c: Int) = fillRect(x, minOf(y0, y1), 1, Math.abs(y1 - y0) + 1, c)

    fun frame(r: Rect, c: Int) {
        hline(r.x, r.right - 1, r.y, c); hline(r.x, r.right - 1, r.bottom - 1, c)
        vline(r.x, r.y, r.bottom - 1, c); vline(r.right - 1, r.y, r.bottom - 1, c)
    }

    fun line(x0: Int, y0: Int, x1: Int, y1: Int, c: Int) {
        var x = x0; var y = y0
        val dx = Math.abs(x1 - x0); val dy = -Math.abs(y1 - y0)
        val sx = if (x0 < x1) 1 else -1; val sy = if (y0 < y1) 1 else -1
        var err = dx + dy
        while (true) {
            plot(x, y, c)
            if (x == x1 && y == y1) break
            val e2 = 2 * err
            if (e2 >= dy) { err += dy; x += sx }
            if (e2 <= dx) { err += dx; y += sy }
        }
    }

    /**
     * Draws one 8x8 TempleOS glyph; bg < 0 is transparent. With [scale] > 1 every font pixel is a
     * scale x scale block of logical pixels (integer magnification: as crisp as the font itself).
     */
    fun glyph(x: Int, y: Int, ch: Int, fg: Int, bg: Int = -1, underline: Boolean = false, scale: Int = 1) {
        if (scale > 1) { glyphScaled(x, y, ch, fg, bg, underline, scale); return }
        if (x >= clip.right || y >= clip.bottom || x + 8 <= clip.x || y + 8 <= clip.y) return
        val code = ch and 0xFF
        val fb = if (code in 0x10..0x1B && isBlank(code)) UI_GLYPHS[code - 0x10] else null
        val base = code * 8
        val f = fg.toByte(); val b = bg.toByte()
        for (r in 0 until 8) {
            val yy = y + r
            if (yy < clip.y || yy >= clip.bottom) continue
            var bits = if (fb != null) (fb[r].toInt() and 0xFF) else (font[base + r].toInt() and 0xFF)
            if (underline && r == 7) bits = 0xFF
            val row = yy * width
            for (c in 0 until 8) {
                val xx = x + c
                if (xx < clip.x || xx >= clip.right) continue
                if ((bits ushr c) and 1 != 0) px[row + xx] = f else if (bg >= 0) px[row + xx] = b
            }
        }
    }

    private fun glyphScaled(x: Int, y: Int, ch: Int, fg: Int, bg: Int, underline: Boolean, k: Int) {
        if (x >= clip.right || y >= clip.bottom || x + 8 * k <= clip.x || y + 8 * k <= clip.y) return
        val code = ch and 0xFF
        val fb = if (code in 0x10..0x1B && isBlank(code)) UI_GLYPHS[code - 0x10] else null
        val base = code * 8
        for (r in 0 until 8) {
            var bits = if (fb != null) (fb[r].toInt() and 0xFF) else (font[base + r].toInt() and 0xFF)
            if (underline && r == 7) bits = 0xFF
            for (c in 0 until 8) {
                val on = (bits ushr c) and 1 != 0
                if (on) fillRect(x + c * k, y + r * k, k, k, fg) else if (bg >= 0) fillRect(x + c * k, y + r * k, k, k, bg)
            }
        }
    }

    private fun isBlank(code: Int): Boolean { for (r in 0 until 8) if (font[code * 8 + r].toInt() != 0) return false; return true }

    /** Draws text with 8x8 cells (magnified by [scale]). Returns the x after the last char. */
    fun text(x: Int, y: Int, s: String, fg: Int, bg: Int = -1, scale: Int = 1): Int {
        var cx = x
        for (ch in s) { glyph(cx, y, ch.code and 0xFF, fg, bg, scale = scale); cx += 8 * scale }
        return cx
    }

    /** Draws a TempleOS cell (char | fg<<8 | bg<<12 | flags) at pixel (x,y). */
    fun cell(x: Int, y: Int, cell: Int) {
        var fg = (cell ushr 8) and 15
        var bg = (cell ushr 12) and 15
        if (cell and 0x20000000 != 0) { val t = fg; fg = bg; bg = t }
        glyph(x, y, cell and 0xFF, fg, bg, underline = cell and 0x80000000.toInt() != 0)
    }

    /**
     * TempleOS window border using the font's box-drawing glyphs 2..13
     * (double lines when [solid]); the title is drawn into the top edge.
     */
    fun border(r: Rect, fg: Int, bg: Int, solid: Boolean, title: String? = null) {
        val s = if (solid) 1 else 0
        val cols = r.w / 8; val rows = r.h / 8
        if (cols < 2 || rows < 2) return
        for (i in 1 until cols - 1) {
            glyph(r.x + i * 8, r.y, 2 + s, fg, bg)
            glyph(r.x + i * 8, r.y + (rows - 1) * 8, 2 + s, fg, bg)
        }
        for (j in 1 until rows - 1) {
            glyph(r.x, r.y + j * 8, 4 + s, fg, bg)
            glyph(r.x + (cols - 1) * 8, r.y + j * 8, 4 + s, fg, bg)
        }
        glyph(r.x, r.y, 6 + s, fg, bg)
        glyph(r.x + (cols - 1) * 8, r.y, 8 + s, fg, bg)
        glyph(r.x, r.y + (rows - 1) * 8, 10 + s, fg, bg)
        glyph(r.x + (cols - 1) * 8, r.y + (rows - 1) * 8, 12 + s, fg, bg)
        if (title != null && cols > 4) {
            // the title lives in the 8-row border band: what is drawn under it (a window's chrome bar) is not an
            // occluder, so a platform-drawn title is fitted to the band (runInkBox), as the TempleOS glyphs are
            withClip(Rect(r.x, r.y, r.w, 8)) { uiText(r.x + 16, r.y, title, fg, (cols - 4) * 8, bg) }
        }
    }

    /** Copies an indexed image (e.g. a program frame) scaled by nearest neighbour into [dst]. */
    /** Draws [part] of the [sw]x[sh] indexed image [src] scaled into [dst] (nearest neighbour). */
    fun blitScaled(src: ByteArray, sw: Int, sh: Int, dst: Rect, part: Rect = Rect(0, 0, sw, sh)) {
        if (dst.w <= 0 || dst.h <= 0) return
        val x0 = maxOf(dst.x, clip.x); val y0 = maxOf(dst.y, clip.y)
        val x1 = minOf(dst.right, clip.right); val y1 = minOf(dst.bottom, clip.bottom)
        for (y in y0 until y1) {
            val sy = part.y + (y - dst.y) * part.h / dst.h
            val srow = sy * sw + part.x
            val drow = y * width
            for (x in x0 until x1) px[drow + x] = src[srow + (x - dst.x) * part.w / dst.w]
        }
    }
}

fun Rect.intersect(o: Rect): Rect {
    val x0 = maxOf(x, o.x); val y0 = maxOf(y, o.y)
    val x1 = minOf(right, o.right); val y1 = minOf(bottom, o.bottom)
    return Rect(x0, y0, maxOf(0, x1 - x0), maxOf(0, y1 - y0))
}

/**
 * Shell-only glyphs for codes 0x10..0x1B, which are blank in the TempleOS font
 * (TempleOS uses them as control codes). Bit 0 is the leftmost pixel.
 */
private val UI_GLYPHS: Array<ByteArray?> = arrayOfNulls<ByteArray>(12).also { g ->
    fun b(vararg r: Int) = ByteArray(8) { (r.getOrElse(it) { 0 }).toByte() }
    g[0x00] = b(0x02, 0x06, 0x0E, 0x1E, 0x0E, 0x06, 0x02)      // 0x10 right triangle
    g[0x01] = b(0x40, 0x60, 0x70, 0x78, 0x70, 0x60, 0x40)      // 0x11 left triangle
    g[0x08] = b(0x18, 0x3C, 0x7E, 0x18, 0x18, 0x18, 0x18)      // 0x18 up arrow
    g[0x09] = b(0x18, 0x18, 0x18, 0x18, 0x7E, 0x3C, 0x18)      // 0x19 down arrow
    g[0x0A] = b(0x00, 0x20, 0x60, 0xFF, 0x60, 0x20)            // 0x1A right arrow
    g[0x0B] = b(0x00, 0x04, 0x06, 0xFF, 0x06, 0x04)            // 0x1B left arrow
}
