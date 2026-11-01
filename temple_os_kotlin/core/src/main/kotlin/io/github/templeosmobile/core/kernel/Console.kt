package io.github.templeosmobile.core.kernel

/**
 * A program window's text document (the TempleOS "put_doc"). Output bytes are
 * interpreted for control characters and DolDoc inline commands ($FG,n$, color
 * names, $BG$, $CL$, $IV$, $UL$, $BK$, links...). Lines are stored unwrapped as
 * cells: bits 0-7 char, 8-11 fg, 12-15 bg, plus ATTRF_* flags (TempleOS layout).
 *
 * Thread-safe: written by the kernel thread, read by the UI thread.
 */
class Console(private val maxLines: Int = 2000) {
    companion object {
        const val ATTRF_BLINK = 0x10000000
        const val ATTRF_INVERT = 0x20000000
        const val MAX_COLS = 1024
        const val ATTRF_UNDERLINE = 0x80000000.toInt()
        const val DFT_FG = 1   // BLUE
        const val DFT_BG = 15  // WHITE
        val COLOR_NAMES = mapOf(
            "BLACK" to 0, "BLUE" to 1, "GREEN" to 2, "CYAN" to 3, "RED" to 4, "PURPLE" to 5,
            "BROWN" to 6, "LTGRAY" to 7, "DKGRAY" to 8, "LTBLUE" to 9, "LTGREEN" to 10,
            "LTCYAN" to 11, "LTRED" to 12, "LTPURPLE" to 13, "YELLOW" to 14, "WHITE" to 15,
        )
    }

    class Line {
        var cells = IntArray(16)
        var len = 0
        fun put(col: Int, cell: Int) {
            if (col >= cells.size) cells = cells.copyOf(maxOf(col + 1, cells.size * 2))
            while (len < col) { cells[len] = ' '.code or (cellAttrBlank shl 8); len++ }
            cells[col] = cell
            if (col >= len) len = col + 1
        }
        fun copy(): Line { val l = Line(); l.cells = cells.copyOf(maxOf(len, 1)); l.len = len; l.fill = fill; return l }
        /**
         * Color attribute the rest of the line takes at its newline (-1: none). TempleOS's DolDoc fills
         * the rest of the row with the current colors at every newline (Adam/DolDoc/DocRecalc.HC:724
         * TextLenAttr), so a $BG$ color reaches the window edge (ZoneOut's sky, CastleFrankenstein).
         */
        var fill = -1
        var cellAttrBlank = (DFT_BG shl 4) or DFT_FG
    }

    private val lines = ArrayList<Line>().apply { add(Line()) }
    /** Raster of an inline DolDoc sprite, anchored at the insertion cell. */
    class DocSprite(val id:Int,var pixels: ByteArray, var width: Int, var height: Int, var x: Int, var y: Int,
                    var row: Int, val col: Int, val format:String="")
    private val sprites = ArrayList<DocSprite>()
    private var nextSpriteId=0
    @Synchronized fun hasSprite(id:Int)=sprites.any {it.id==id}
    @Synchronized fun writeKeepingSprites(bytes:ByteArray) {
        val saved=sprites.toList();write(bytes);sprites.clear();sprites.addAll(saved)
    }
    @Synchronized fun resizeSprite(id:Int,side:Int) {
        val sp=sprites.firstOrNull {it.id==id} ?: return
        if(side !in 1..1024 || sprites.sumOf {it.pixels.size.toLong()}-sp.pixels.size+side.toLong()*side>4L*1024*1024)
            throw io.github.templeosmobile.core.holyc.VmKill("document sprite size")
        sp.width=side;sp.height=side;sp.x = -side/2;sp.y = -side/2;sp.pixels=ByteArray(side*side) {(-1).toByte()}
    }
    @Synchronized fun updateSprite(id:Int,fill:(ByteArray)->Unit) {
        val sp=sprites.firstOrNull {it.id==id} ?: return;fill(sp.pixels);version++
    }
    @Synchronized fun cursorCell() = row to col
    @Synchronized fun updateField(atRow:Int,atCol:Int,bytes:ByteArray,color:Int) {
        if(atRow !in lines.indices || atCol !in 0 until MAX_COLS) return
        for(i in bytes.indices.take(MAX_COLS-atCol)) lines[atRow].put(atCol+i,(bytes[i].toInt() and 255) or (((bg shl 4) or color) shl 8))
        version++
    }
    private var firstVisualRow = 0
    @Synchronized fun insertSprite(pixels: ByteArray, width: Int, height: Int, x: Int, y: Int, format:String=""):Int {
        if (sprites.size >= 64 || sprites.sumOf { it.pixels.size.toLong() } + pixels.size > 4L * 1024 * 1024)
            throw io.github.templeosmobile.core.holyc.VmKill("document sprite limit")
        val id=++nextSpriteId
        sprites.add(DocSprite(id,pixels, width, height, x, y, row, col,format))
        version++
        return id
    }
    class SpriteLink(val x:Int,val y:Int,val width:Int,val height:Int,val format:String)
    @Synchronized fun spriteLinks(cols:Int):List<SpriteLink> {
        if(cols<=0) return emptyList()
        return sprites.filter {it.format.contains(",LM=")}.mapNotNull {sp ->
            var vr=0;for(i in 0 until minOf(sp.row,lines.size)) vr+=maxOf(1,(lines[i].len+cols-1)/cols)
            val x=(sp.col%cols)*8L+sp.x;val y=(vr+sp.col/cols-firstVisualRow)*8L+sp.y
            if(x !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() || y !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) null
            else SpriteLink(x.toInt(),y.toInt(),sp.width,sp.height,sp.format)
        }
    }
    /** Draw document sprites before draw_it, using the same wrapping/scroll origin as text. */
    @Synchronized fun renderSprites(dst: ByteArray, stride: Int, left: Int, top: Int, cols: Int, rows: Int) {
        for (sp in sprites) {
            var vr = 0
            for (i in 0 until minOf(sp.row,lines.size)) vr += maxOf(1, (lines[i].len + cols - 1) / cols)
            val x0 = left.toLong() + (sp.col % cols) * 8L + sp.x
            val y0 = top.toLong() + (vr + sp.col / cols - firstVisualRow) * 8L + sp.y
            val x1 = maxOf(left.toLong(), x0); val x2 = minOf(left.toLong() + cols * 8L, x0 + sp.width)
            val y1 = maxOf(top.toLong(), y0); val y2 = minOf(top.toLong() + rows * 8L, y0 + sp.height)
            for (y in y1 until y2) for (x in x1 until x2) {
                val c = sp.pixels[((y - y0) * sp.width + x - x0).toInt()]
                if (c.toInt() != -1) dst[y.toInt() * stride + x.toInt()] = c
            }
        }
    }
    private var row = 0
    private var col = 0
    var fg = DFT_FG; private set
    var bg = DFT_BG; private set
    private var flags = 0
    private var fgStack = ArrayList<Int>()
    /** Incremented on every change; the UI re-renders when it differs. */
    @Volatile var version = 0L
        private set
    var cursorVisible = true
    /** Line being edited by GetStr (shown after the output), or null. */
    var inputLine: String? = null
        private set
    var inputCursor = 0
        private set
    var defaultFg = DFT_FG
    var defaultBg = DFT_BG

    // pending partial DolDoc command spanning writes
    private val pending = StringBuilder()
    private var inCmd = false

    @Synchronized fun clear() {
        lines.clear(); lines.add(Line())
        row = 0; col = 0; sprites.clear(); firstVisualRow = 0
        version++
    }

    @Synchronized fun setColors(fgc: Int, bgc: Int) {
        defaultFg = fgc; defaultBg = bgc; fg = fgc; bg = bgc
        version++
    }

    @Synchronized fun setInput(s: String?, cursor: Int) {
        // The terminal re-asserts its input line every UI tick: only a real change is a new version
        // (otherwise the window redraws at the display rate and starves the interpreter threads).
        if (s == inputLine && cursor == inputCursor) return
        inputLine = s; inputCursor = cursor; version++
    }

    /** Writes raw TempleOS text (bytes 0..255). */
    @Synchronized fun write(bytes: ByteArray, off: Int = 0, len: Int = bytes.size) {
        for (i in off until off + len) put(bytes[i].toInt() and 0xFF)
        version++
    }

    fun write(s: String) = write(ByteArray(s.length) { s[it].code.toByte() })

    private fun put(c: Int) {
        if (inCmd) {
            if (c == '$'.code) {
                inCmd = false
                if (pending.isEmpty()) emit('$'.code) else command(pending.toString())
                pending.setLength(0)
            } else if (c == '\n'.code || pending.length > 512) {
                // unterminated: print literally
                inCmd = false
                emit('$'.code)
                val s = pending.toString(); pending.setLength(0)
                for (ch in s) emit(ch.code)
                emit(c)
            } else pending.append(c.toChar())
            return
        }
        when (c) {
            '$'.code -> inCmd = true
            else -> emit(c)
        }
    }

    private fun emit(c: Int) {
        when (c) {
            '\n'.code -> { if (col >= lines[row].len) lines[row].fill = attr(); newLine() }
            '\r'.code -> col = 0
            '\t'.code -> { val n = 8 - (col and 7); repeat(n) { cell(' '.code) } }
            8 -> if (col > 0) { col--; lines[row].put(col, ' '.code or (attr() shl 8)) }
            12 -> clearLocked()
            0 -> {}
            else -> cell(c)
        }
    }

    private fun clearLocked() { lines.clear(); lines.add(Line()); row = 0; col = 0; sprites.clear(); firstVisualRow = 0 }

    private fun attr(): Int = (bg shl 4) or fg

    private fun cell(c: Int) {
        // bounded memory: very long lines wrap (MAX_COLS x maxLines cells at most)
        if (col >= MAX_COLS) newLine()
        lines[row].put(col, (c and 0xFF) or (attr() shl 8) or flags)
        col++
    }

    private fun newLine() {
        row++
        col = 0
        if (row >= lines.size) lines.add(Line())
        while (lines.size > maxLines) { lines.removeAt(0); row--; sprites.forEach { it.row-- }; sprites.removeAll { it.row < 0 } }
    }

    private fun colorArg(s: String): Int? {
        val v = s.trim()
        COLOR_NAMES[v]?.let { return it }
        return v.toIntOrNull()
    }

    private fun command(cmd: String) {
        val code = cmd.take(2)
        val rest = if (cmd.length > 2) cmd.substring(2) else ""
        val args = splitArgs(rest)
        COLOR_NAMES[cmd]?.let { fg = it; return }
        when (code) {
            "FG" -> fg = if (args.isEmpty()) defaultFg else colorArg(args[0]) ?: fg
            "BG" -> bg = if (args.isEmpty()) defaultBg else colorArg(args[0]) ?: bg
            "FD" -> { defaultFg = colorArg(args.getOrNull(0) ?: "") ?: defaultFg }
            "BD" -> { defaultBg = colorArg(args.getOrNull(0) ?: "") ?: defaultBg }
            "CL" -> clearLocked()
            "PT" -> fg = 2 // prompt color
            "IV" -> flags = setFlag(flags, ATTRF_INVERT, cmd)
            "UL" -> flags = setFlag(flags, ATTRF_UNDERLINE, cmd)
            "BK" -> flags = setFlag(flags, ATTRF_BLINK, cmd)
            "CM", "CH", "ID", "WW", "HL", "LM", "RM", "SY", "SP", "IB", "IS", "BP", "MA", "BT", "CB",
            "DA", "HC", "ER", "PI", "AN", "HI", "LS", "TR", "MU", "CU", "HX", "SO", "SU", "SX", "WR" -> {
                // tags with visible text: show it
                val tag = args.firstOrNull { it.startsWith("\"") }
                if (tag != null && code !in setOf("IB", "IS", "ID", "WW", "HL", "LM", "RM", "SY", "BP", "CM")) {
                    for (ch in unquote(tag)) cell(ch.code)
                }
            }
            "TX", "LK", "TI" -> {
                val tag = args.firstOrNull { it.startsWith("\"") } ?: return
                val save = flags
                if (code == "LK") flags = flags or ATTRF_UNDERLINE
                for (ch in unquote(tag)) cell(ch.code)
                flags = save
            }
            else -> {
                // unknown command: if it looks like plain text with $ (e.g. "$5"), print verbatim
                if (cmd.isNotEmpty() && !cmd[0].isUpperCase()) {
                    emit('$'.code); for (ch in cmd) emit(ch.code); emit('$'.code)
                }
            }
        }
    }

    private fun setFlag(f: Int, bit: Int, cmd: String): Int {
        val on = !cmd.endsWith(",0") && !cmd.endsWith("-0")
        return if (on && cmd.length > 2 && cmd.contains(",1")) f or bit
        else if (cmd.length == 2) f or bit
        else if (on) f or bit else f and bit.inv()
    }

    private fun splitArgs(s: String): List<String> {
        val res = ArrayList<String>()
        val sb = StringBuilder()
        var q = false
        var i = 0
        val t = s.trimStart(',', '+', '-')
        while (i < t.length) {
            val c = t[i]
            if (c == '"') q = !q
            if (c == '\\' && q && i + 1 < t.length) { sb.append(c).append(t[i + 1]); i += 2; continue }
            if (c == ',' && !q) { res.add(sb.toString()); sb.setLength(0) } else sb.append(c)
            i++
        }
        if (sb.isNotEmpty()) res.add(sb.toString())
        return res
    }

    private fun unquote(s: String): String {
        val t = s.trim()
        if (t.length < 2 || !t.startsWith("\"")) return t
        val body = t.substring(1, t.lastIndexOf('"').coerceAtLeast(1))
        val sb = StringBuilder()
        var i = 0
        while (i < body.length) {
            if (body[i] == '\\' && i + 1 < body.length) {
                sb.append(when (body[i + 1]) { 'n' -> '\n'; 't' -> '\t'; 'd' -> '$'; else -> body[i + 1] }); i += 2
            } else sb.append(body[i++])
        }
        return sb.toString()
    }

    // ------------------------------------------------------------ readers

    /** Plain text of the whole document (DolDoc removed), newline separated. */
    @Synchronized fun plainText(): String {
        val sb = StringBuilder()
        for ((i, l) in lines.withIndex()) {
            for (c in 0 until l.len) sb.append((l.cells[c] and 0xFF).toChar())
            if (i < lines.size - 1) sb.append('\n')
        }
        return sb.toString()
    }

    /** The last [n] non-blank lines as plain text (for screen readers; no full copy). */
    @Synchronized fun tailText(n: Int): String {
        val out = ArrayList<String>()
        var i = lines.size - 1
        while (i >= 0 && out.size < n) {
            val l = lines[i--]
            val sb = StringBuilder()
            for (c in 0 until l.len) sb.append((l.cells[c] and 0xFF).toChar())
            if (sb.isNotBlank()) out.add(sb.toString().trimEnd())
        }
        return out.asReversed().joinToString("\n")
    }

    /** Snapshot of all lines (copies). */
    @Synchronized fun snapshot(): List<Line> = lines.map { it.copy() }

    @Synchronized fun lineCount() = lines.size
    @Synchronized fun cursorRow() = row
    @Synchronized fun cursorCol() = col

    /**
     * Renders the document into a TempleOS text_base style cell grid ([cols] x
     * [rows]), wrapping lines and scrolling so the cursor row is visible.
     */
    /** Visual rows of the document at [cols] columns (for scroll bars). */
    @Synchronized fun visualRows(cols: Int): Int {
        var n = 0
        for (l in lines) n += maxOf(1, (l.len + cols - 1) / cols)
        return n + (if (inputLine != null) 1 else 0)
    }

    @Synchronized fun renderCells(dst: IntArray, cols: Int, rows: Int, blankAttr: Int, scrollBack: Int = 0) {
        val blank = ' '.code or (blankAttr shl 8)
        java.util.Arrays.fill(dst, 0, cols * rows, blank)
        // wrap into visual rows
        val vis = ArrayList<IntArray>()
        var cursorVis = 0
        for ((i, l) in lines.withIndex()) {
            var c = 0
            if (i == row) cursorVis = vis.size + col / cols
            val fillCell = if (l.fill >= 0) ' '.code or (l.fill shl 8) else -1
            if (l.len == 0) vis.add(if (fillCell >= 0) IntArray(cols) { fillCell } else IntArray(0))
            while (c < l.len) {
                val n = minOf(cols, l.len - c)
                val v = l.cells.copyOfRange(c, c + n)
                c += n
                // the row's rest takes the newline's colors
                vis.add(if (c >= l.len && fillCell >= 0 && n < cols) v.copyOf(cols).also { java.util.Arrays.fill(it, n, cols, fillCell) } else v)
            }
        }
        val il = inputLine
        if (il != null && vis.isNotEmpty()) {
            val last = vis.removeAt(vis.size - 1)
            val merged = IntArray(last.size + il.length)
            System.arraycopy(last, 0, merged, 0, last.size)
            for (j in il.indices) merged[last.size + j] = (il[j].code and 0xFF) or (((defaultBg shl 4) or defaultFg) shl 8)
            var c = 0
            do {
                val n = minOf(cols, merged.size - c)
                vis.add(merged.copyOfRange(c, c + maxOf(n, 0)))
                c += cols
            } while (c < merged.size)
            cursorVis = vis.size - 1
        }
        val first = maxOf(0, maxOf(cursorVis, vis.size - 1) - rows + 1 - scrollBack)
        firstVisualRow = first
        for (r in 0 until rows) {
            val v = vis.getOrNull(first + r) ?: break
            System.arraycopy(v, 0, dst, r * cols, minOf(v.size, cols))
        }
    }
}
