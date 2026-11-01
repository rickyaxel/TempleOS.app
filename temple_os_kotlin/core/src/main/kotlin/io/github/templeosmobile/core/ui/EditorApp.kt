package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*

/**
 * HolyC source editor. Edits the text part of a file; a DolDoc binary section
 * (embedded sprites) is preserved unchanged on save. Source is saved only in
 * the app's virtual drive; there is no import from outside the app.
 */
class EditorApp(shell: Shell, initialPath: String?, draft: String? = null) : App(shell) {
    override val kind = "editor"
    var path: String? = initialPath; private set
    override val title get() = InputCharacterPolicy.display(path?.substringAfterLast('/') ?: "Untitled.HC") + if (modified) "*" else ""
    override val wantsKeyboard get() = true

    val lines = ArrayList<String>()
    private var binTail: ByteArray = ByteArray(0)
    var row = 0; private set
    var col = 0; private set
    private var anchorRow = -1; private var anchorCol = 0 // selection anchor (-1 = none)
    private var top = 0
    private var left = 0
    var modified = false; private set
    private val undo = ArrayList<Snapshot>()
    private val redo = ArrayList<Snapshot>()
    private var errorLine = -1
    private var errorMsg: String? = null
    private var program: ProgramApp? = null
    private var lastEditTime = 0L
    private var visibleRows = 20
    private var textCols = 40
    private var gutter = 32

    private class Snapshot(val text: String, val row: Int, val col: Int)
    private val hl = Highlighter(lines)

    init {
        val data = initialPath?.let { shell.fs.readFile(it) }
        if (data != null) {
            val end = data.indexOf(0.toByte())
            binTail = if (end >= 0) data.copyOfRange(end, data.size) else ByteArray(0)
            setText(textPart(data).replace("\r", ""))
        } else setText(if (initialPath == null) TEMPLATE else "")
        if (draft != null && draft != text()) { setText(draft); modified = true }
    }

    fun text(): String = lines.joinToString("\n")

    private fun setText(t: String) {
        lines.clear(); lines.addAll(t.split('\n'))
        if (lines.isEmpty()) lines.add("")
        row = row.coerceIn(0, lines.size - 1); col = col.coerceIn(0, lines[row].length)
        hl.invalidateFrom(0)
    }

    // ------------------------------------------------------------ editing primitives

    private fun snapshot(force: Boolean = false) {
        val now = shell.env.nowMs()
        if (!force && now - lastEditTime < 800 && undo.isNotEmpty()) { lastEditTime = now; return }
        lastEditTime = now
        undo.add(Snapshot(text(), row, col))
        if (undo.size > 200) undo.removeAt(0)
        redo.clear()
    }

    private fun changed(fromRow: Int) {
        modified = true
        errorLine = -1
        hl.invalidateFrom(fromRow)
        invalidate()
    }

    fun insert(s: String) {
        if (!InputCharacterPolicy.isByteText(s)) { shell.rejectInput(); return }
        snapshot(force = s.contains('\n'))
        deleteSelectionNoSnap()
        val cur = lines[row]
        val before = cur.substring(0, col); val after = cur.substring(col)
        val parts = (before + s + after).split('\n')
        lines[row] = parts[0]
        for (i in 1 until parts.size) lines.add(row + i, parts[i])
        val lastLen = parts.last().length - after.length
        val startRow = row
        row += parts.size - 1
        col = if (parts.size == 1) before.length + s.length else lastLen
        changed(startRow)
        ensureVisible()
    }

    private fun newline() {
        // keep the current line's indentation, like the TempleOS editor
        val indent = lines[row].takeWhile { it == ' ' || it == '\t' }
        val extra = if (lines[row].substring(0, col).trimEnd().endsWith("{")) "  " else ""
        insert("\n" + indent + extra)
    }

    private fun backspace() {
        if (hasSelection()) { snapshot(true); deleteSelectionNoSnap(); changed(row); return }
        snapshot()
        if (col > 0) { lines[row] = lines[row].removeRange(col - 1, col); col-- }
        else if (row > 0) { col = lines[row - 1].length; lines[row - 1] += lines[row]; lines.removeAt(row); row-- }
        changed(row); ensureVisible()
    }

    private fun deleteForward() {
        if (hasSelection()) { snapshot(true); deleteSelectionNoSnap(); changed(row); return }
        snapshot()
        if (col < lines[row].length) lines[row] = lines[row].removeRange(col, col + 1)
        else if (row < lines.size - 1) { lines[row] += lines[row + 1]; lines.removeAt(row + 1) }
        changed(row)
    }

    fun hasSelection() = anchorRow >= 0 && (anchorRow != row || anchorCol != col)

    private fun selRange(): IntArray {
        val a = anchorRow * 100000L + anchorCol; val b = row * 100000L + col
        return if (a <= b) intArrayOf(anchorRow, anchorCol, row, col) else intArrayOf(row, col, anchorRow, anchorCol)
    }

    fun selectedText(): String {
        if (!hasSelection()) return ""
        val (r0, c0, r1, c1) = selRange().let { listOf(it[0], it[1], it[2], it[3]) }
        if (r0 == r1) return lines[r0].substring(c0, c1)
        val sb = StringBuilder(lines[r0].substring(c0))
        for (r in r0 + 1 until r1) sb.append('\n').append(lines[r])
        sb.append('\n').append(lines[r1].substring(0, c1))
        return sb.toString()
    }

    private fun deleteSelectionNoSnap() {
        if (!hasSelection()) { anchorRow = -1; return }
        val s = selRange()
        val keep = lines[s[0]].substring(0, s[1]) + lines[s[2]].substring(s[3])
        for (i in s[2] downTo s[0] + 1) lines.removeAt(i)
        lines[s[0]] = keep
        row = s[0]; col = s[1]
        anchorRow = -1
    }

    fun undo() {
        val s = undo.removeLastOrNull() ?: return
        redo.add(Snapshot(text(), row, col))
        setText(s.text); row = s.row.coerceIn(0, lines.size - 1); col = s.col.coerceIn(0, lines[row].length)
        modified = true; anchorRow = -1; invalidate(); ensureVisible()
    }

    fun redo() {
        val s = redo.removeLastOrNull() ?: return
        undo.add(Snapshot(text(), row, col))
        setText(s.text); row = s.row.coerceIn(0, lines.size - 1); col = s.col.coerceIn(0, lines[row].length)
        modified = true; anchorRow = -1; invalidate(); ensureVisible()
    }

    private fun move(dr: Int, dc: Int, select: Boolean) {
        if (select && anchorRow < 0) { anchorRow = row; anchorCol = col }
        if (!select) anchorRow = -1
        if (dr != 0) { row = (row + dr).coerceIn(0, lines.size - 1); col = col.coerceAtMost(lines[row].length) }
        if (dc < 0) { if (col > 0) col-- else if (row > 0) { row--; col = lines[row].length } }
        if (dc > 0) { if (col < lines[row].length) col++ else if (row < lines.size - 1) { row++; col = 0 } }
        ensureVisible(); invalidate()
    }

    private fun ensureVisible() {
        if (row < top) top = row
        if (row >= top + visibleRows) top = row - visibleRows + 1
        val vc = visualCol(row, col)
        if (vc < left) left = maxOf(0, vc - 4)
        if (vc >= left + textCols) left = vc - textCols + 4
    }

    private fun visualCol(r: Int, c: Int): Int {
        var v = 0
        val l = lines[r]
        for (i in 0 until minOf(c, l.length)) v = if (l[i] == '\t') (v / 8 + 1) * 8 else v + 1
        return v
    }

    private fun colFromVisual(r: Int, vc: Int): Int {
        var v = 0
        val l = lines[r]
        for (i in l.indices) {
            val nv = if (l[i] == '\t') (v / 8 + 1) * 8 else v + 1
            if (nv > vc) return i
            v = nv
        }
        return l.length
    }

    // ------------------------------------------------------------ file operations

    fun save(as_: String? = null): Boolean {
        val target = as_ ?: path ?: run { saveAs(); return false }
        if (!InputCharacterPolicy.isByteBuffer(text())) { shell.rejectInput(); return false }
        val t = latin1(text())
        val data = if (binTail.isNotEmpty()) t + binTail else t
        return try {
            shell.fs.writeFile(target, data)
            path = target; modified = false
            shell.showToast( { tr("toast.saved", "path" to InputCharacterPolicy.display(target)) })
            shell.saveSession()
            invalidate(); true
        } catch (e: FsError) {
            shell.showDialog(Dialog.confirm( { tr("editor.save_failed.title") }, { e.localized() }, { tr("button.ok") }) {}); false
        }
    }

    fun saveAs(afterSave:(()->Unit)? = null) {
        val initial = path ?: "C:/Home/Untitled.HC"
        shell.showDialog(Dialog.input( { tr("editor.dialog.save_as") }, initial) { p ->
            if (p == null) return@input
            val norm = Paths.normalize("C:/Home", p)
            if (norm == null || norm == "C:/") { shell.showToast( { tr("toast.invalid_path") }); return@input }
            val withExt = if (Paths.name(norm).contains('.')) norm else "$norm.HC"
            if (shell.fs.exists(withExt) && withExt != path) {
                shell.showDialog(Dialog.confirmDestructive( { tr("dialog.replace.title", "name" to InputCharacterPolicy.display(Paths.name(withExt))) }, { tr("dialog.replace.message") }, { tr("button.replace") }) { if(save(withExt))afterSave?.invoke() })
            } else if(save(withExt))afterSave?.invoke()
        })
    }

    fun run() {
        if (!InputCharacterPolicy.isByteBuffer(text())) { shell.rejectInput(); return }
        program?.let { p -> shell.windows.firstOrNull { it.app === p }?.let { shell.close(it, true) } }
        val src = latin1(text()) + binTail
        val runPath = path ?: "C:/Home/Untitled.HC"
        // the user's own HolyC is compiled on the device: it always runs in Pure Terry
        val p = ProgramApp(shell, runPath, null, src)
        program = p
        p.navigationParentId=shell.windows.firstOrNull {it.app===this}?.id
        shell.open(p, maximized = !shell.landscape)
        if (shell.settings.engine == Settings.ENGINE_NATIVE) shell.showToast( { tr("engine.custom_terry", "engine" to Engines.TERRY_NAME) })
        // collect compile errors for highlighting once the program reports them
        Thread {
            val start = System.currentTimeMillis()
            while (System.currentTimeMillis() - start < 8000) {
                Thread.sleep(150)
                val txt = p.kernel.console.plainText()
                val m = Regex("Compile error: (.*?):(\\d+): (.*)").find(txt)
                if (m != null) {
                    if (m.groupValues[1].equals(runPath, ignoreCase = true)) shell.post {
                        errorLine = m.groupValues[2].toInt() - 1; errorMsg = m.groupValues[3]
                        if (errorLine in lines.indices) { row = errorLine; col = 0; ensureVisible() }
                        invalidate()
                    }
                    break
                }
                if (p.isFinished || txt.length > 2) break
            }
        }.apply { isDaemon = true }.start()
    }

    // ------------------------------------------------------------ input

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (!down) return true
        val code = (sc and 0x7F).toInt()
        val ctrl = sc and Keys.SCF_CTRL != 0L
        val shift = sc and Keys.SCF_SHIFT != 0L
        if (ctrl) {
            when ((ch or 0x60).toChar()) {
                's' -> { save(); return true }
                'z' -> { undo(); return true }
                'y' -> { redo(); return true }
                'c' -> { shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); return true }
                'x' -> { shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); snapshot(true); deleteSelectionNoSnap(); changed(row); return true }
                'v' -> { shell.pasteClipboard(); return true }
                'a' -> { anchorRow = 0; anchorCol = 0; row = lines.size - 1; col = lines[row].length; invalidate(); return true }
            }
        }
        if (ch == 0 || code == Keys.SC_DELETE) {
            when (code) {
                Keys.SC_CURSOR_LEFT -> move(0, -1, shift)
                Keys.SC_CURSOR_RIGHT -> move(0, 1, shift)
                Keys.SC_CURSOR_UP -> move(-1, 0, shift)
                Keys.SC_CURSOR_DOWN -> move(1, 0, shift)
                Keys.SC_HOME -> { if (!shift) anchorRow = -1; col = 0; invalidate() }
                Keys.SC_END -> { if (!shift) anchorRow = -1; col = lines[row].length; invalidate() }
                Keys.SC_PAGE_UP -> move(-visibleRows, 0, shift)
                Keys.SC_PAGE_DOWN -> move(visibleRows, 0, shift)
                Keys.SC_DELETE -> deleteForward()
                Keys.SC_F1 + 4 -> run() // F5
            }
            return true
        }
        when (ch) {
            '\n'.code -> newline()
            Keys.CH_BACKSPACE -> backspace()
            '\t'.code -> insert("  ")
            Keys.CH_ESC -> { anchorRow = -1; invalidate() }
            else -> if (ch in 32..255) insert(ch.toChar().toString())
        }
        return true
    }

    override fun text(s: String) {
        val t = s.replace("\r", "")
        if (t == "\n") { newline(); return }
        insert(t)
    }

    override fun tap(x: Int, y: Int, r: Rect) {
        val (rr, cc) = posAt(x, y, r) ?: return
        anchorRow = -1; row = rr; col = cc
        shell.requestKeyboard()
        invalidate()
    }

    override fun longPress(x: Int, y: Int, r: Rect) {
        val (rr, cc) = posAt(x, y, r) ?: return
        row = rr
        // select the word under the finger
        val l = lines[rr]
        var a = cc.coerceAtMost(l.length); var b = a
        while (a > 0 && (l[a - 1].isLetterOrDigit() || l[a - 1] == '_')) a--
        while (b < l.length && (l[b].isLetterOrDigit() || l[b] == '_')) b++
        anchorRow = rr; anchorCol = a; col = b
        invalidate()
        shell.showMenu(listOf(
            MenuItem( { tr("menu.copy") }) { shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())) },
            MenuItem( { tr("menu.cut") }) { shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); snapshot(true); deleteSelectionNoSnap(); changed(row) },
            MenuItem( { tr("menu.paste") }) { shell.pasteClipboard() },
            MenuItem( { tr("menu.select_line") }) { anchorRow = rr; anchorCol = 0; col = lines[rr].length; invalidate() },
            MenuItem( { tr("menu.select_all") }) { anchorRow = 0; anchorCol = 0; row = lines.size - 1; col = lines[row].length; invalidate() },
        ), x, y, { tr("menu.edit.title") })
    }

    private fun posAt(x: Int, y: Int, r: Rect): Pair<Int, Int>? {
        val tr = r.y + headerHeight
        if (y < tr) return null
        val rr = (top + (y - tr) / 8).coerceIn(0, lines.size - 1)
        val vc = maxOf(0, (x - r.x - gutter) / 8 + left)
        return rr to colFromVisual(rr, vc)
    }

    private var scrollAccX = 0
    private var scrollAccY = 0

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        scrollAccY -= dy; scrollAccX -= dx
        val rowsMoved = scrollAccY / 8; scrollAccY %= 8
        val colsMoved = scrollAccX / 8; scrollAccX %= 8
        top = (top + rowsMoved).coerceIn(0, maxOf(0, lines.size - visibleRows / 2))
        left = maxOf(0, left + colsMoved)
        invalidate()
    }

    // ------------------------------------------------------------ drawing


    override fun draw(s: Surface, r: Rect) {
        s.fill(r, Palette.WHITE)
        // header: file name + action buttons
        headerButtons.clear()
        val actions = listOf<Pair<String, () -> Unit>>(tr("editor.button.run") to { run() }, tr("editor.button.save") to { save() },
                tr("editor.button.undo") to { undo() }, tr("editor.button.redo") to { redo() })
        val status = "${row + 1}:${col + 1}" + if (modified) " *" else ""
        val layout = s.toolbarLayout(actions.map { it.first }, r, HEADER, status.length * 8 + 4)
        headerHeight = layout.height
        val header = headerHeight
        s.fillRect(r.x, r.y, r.w, header, Palette.LTGRAY)
        for ((i, action) in actions.withIndex()) {
            val (label, act) = action
            val br = layout.buttons[i]
            s.templeButton(br, label, if (headerButtons.isEmpty()) ButtonFace.ACTION else ButtonFace.NORMAL)
            headerButtons.add(br to act)
            a11yButton(br, label)
        }
        s.text(r.right - status.length * 8 - 4, layout.trailing.y + (layout.trailing.h - 8) / 2, status, Palette.BLACK)
        val body = Rect(r.x, r.y + header, r.w, r.h - header - (if (errorMsg != null && errorLine >= 0) 10 else 0))
        a11yText(body, tr(if (modified) "editor.a11y.position_modified" else "editor.a11y.position", "line" to row + 1, "lines" to lines.size, "column" to col + 1) + ": " + InputCharacterPolicy.display(lines[row]))
        visibleRows = maxOf(1, body.h / 8)
        val digits = maxOf(3, (lines.size).toString().length)
        gutter = digits * 8 + 4
        textCols = maxOf(4, (r.w - gutter) / 8)
        top = top.coerceIn(0, maxOf(0, lines.size - 1))
        val sel = if (hasSelection()) selRange() else null
        for (i in 0 until visibleRows) {
            val ln = top + i
            if (ln >= lines.size) break
            val y = body.y + i * 8
            s.text(r.x, y, (ln + 1).toString().padStart(digits), Palette.DKGRAY)
            if (ln == errorLine) s.fillRect(r.x + gutter, y, r.w - gutter, 8, Palette.LTRED)
            else if (ln == row) s.fillRect(r.x + gutter, y, r.w - gutter, 8, 0x0F.let { Palette.WHITE })
            val colors = hl.colors(ln)
            val l = lines[ln]
            var v = 0
            for ((ci, c) in l.withIndex()) {
                val w = if (c == '\t') 8 - (v % 8) else 1
                val vx = v - left
                if (vx in 0 until textCols) {
                    val selected = sel != null && inSel(sel, ln, ci)
                    s.glyph(r.x + gutter + vx * 8, y, if (c == '\t') ' '.code else c.code and 0xFF,
                        if (selected) Palette.WHITE else colors[ci], if (selected) Palette.BLUE else -1)
                }
                v += w
            }
            if (l.any { it.code > 255 }) s.uiText(r.x + gutter, y, lines[ln].drop(left).take(textCols), Palette.BLUE, textCols * 8)
            // V-25: like nano's '$', mark text hidden past either edge
            if (left > 0 && v > 0) s.glyph(r.x + gutter, y, 0x11, Palette.WHITE, Palette.DKGRAY)
            if (v - left > textCols) s.glyph(r.x + gutter + (textCols - 1) * 8, y, 0x10, Palette.WHITE, Palette.DKGRAY)
            if (ln == row) {
                val cx = r.x + gutter + (visualCol(row, col) - left) * 8
                if (cx >= r.x + gutter && cx < r.right && (shell.env.nowMs() / 530) % 2 == 0L) s.fillRect(cx, y, 2, 8, Palette.RED)
            }
        }
        if (errorMsg != null && errorLine >= 0) {
            // the compiler's message stays as HolyC reports it; only the frame is translated
            val t = tr("editor.error_line", "line" to errorLine + 1, "message" to errorMsg!!)
            a11yText(Rect(r.x, r.bottom - 10, r.w, 10), t)
            s.fillRect(r.x, r.bottom - 10, r.w, 10, Palette.RED)
            s.uiText(r.x + 2, r.bottom - 9, t, Palette.WHITE, r.w - 4)
        }
    }

    private fun inSel(s: IntArray, ln: Int, c: Int): Boolean {
        val p = ln * 100000L + c
        return p >= s[0] * 100000L + s[1] && p < s[2] * 100000L + s[3]
    }

    private val headerButtons = ArrayList<Pair<Rect, () -> Unit>>()
    private var headerHeight = Touch.editorHeader

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        if (e.action == Ptr.DOWN && e.y < r.y + headerHeight) {
            headerButtons.firstOrNull { it.first.contains(e.x, e.y) }?.second?.invoke()
            return true
        }
        return false
    }

    override fun tick(nowMs: Long): Boolean = true.takeIf { (nowMs / 530) % 2 != lastBlink }?.also { lastBlink = (nowMs / 530) % 2 } ?: false
    private var lastBlink = -1L

    override fun menu(): List<MenuItem> {
        val close:()->Unit={shell.windows.firstOrNull {it.app===this}?.let {shell.close(it,true)};Unit}
        val sourceActions:Map<String,()->Unit> = mapOf(
            "File/Save" to {save();Unit},"File/SaveAs" to {saveAs()},
            "File/Abort" to close,"File/Exit" to {if(path==null)saveAs(close) else if(save())close()},
            "Edit/Undo" to {undo()},"Edit/Cut" to {shell.env.clipboardSet(InputCharacterPolicy.display(selectedText()));snapshot(true);deleteSelectionNoSnap();changed(row)},
            "Edit/Copy" to {shell.env.clipboardSet(InputCharacterPolicy.display(selectedText()))},"Edit/Paste" to {shell.pasteClipboard()},
            "Edit/GoBegin" to {row=0;col=0;ensureVisible();invalidate()},
            "Edit/GoEnd" to {row=lines.lastIndex;col=lines[row].length;ensureVisible();invalidate()},
            "Edit/GoLeft" to {col=0;ensureVisible();invalidate()},"Edit/GoRight" to {col=lines[row].length;ensureVisible();invalidate()},
            "Program/Include" to {run()},"View/FileMgr" to {Launch.files(shell,path?.let {Paths.parent(it)} ?: "C:/Home")},
            "Help/Menu" to {shell.showStartMenu()},"Help/Help" to {Launch.doc(shell,"C:/Doc/HelpIndex.DD")},"Help/About" to {Launch.about(shell)}
        )
        return OriginalContextMenu.items(shell,"C:/Doc/EdPullDown.DD",sourceActions) + listOf(
        MenuItem( { tr("editor.menu.run") }) { run() },
        MenuItem( { tr("menu.stop_program") }, enabled = program?.isFinished == false) { program?.stop() },
        MenuItem( { tr("editor.menu.save") }) { save() },
        MenuItem( { tr("menu.save_as") }) { saveAs() },
        MenuItem( { tr("editor.menu.new_file") }) { Launch.editor(shell, null) },
        MenuItem( { tr("editor.menu.open_file") }) { Launch.files(shell, path?.let { Paths.parent(it) } ?: "C:/Home") },
        MenuItem( { tr("menu.undo") }) { undo() },
        MenuItem( { tr("menu.redo") }) { redo() },
        MenuItem( { tr("menu.copy") }) { shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())) },
        MenuItem( { tr("menu.paste") }) { shell.pasteClipboard() },
        MenuItem( { tr("menu.select_all") }) { anchorRow = 0; anchorCol = 0; row = lines.size - 1; col = lines[row].length; invalidate() },
        MenuItem( { tr("editor.menu.go_to_top") }) { row = 0; col = 0; top = 0; invalidate() },
    )
    }

    override val unsaved get() = modified

    override fun saveState(): Map<String, String> {
        val m = HashMap<String, String>()
        path?.let { m["path"] = it }
        if (modified && text().length < 200_000) m["draft"] = text()
        m["row"] = row.toString(); m["col"] = col.toString()
        return m
    }

    fun restoreCursor(r: Int, c: Int) { row = r.coerceIn(0, lines.size - 1); col = c.coerceIn(0, lines[row].length); ensureVisible() }

    companion object {
        val HEADER get() = Touch.editorHeader
        const val TEMPLATE = "//New HolyC program. Press RUN to execute it.\n\nU0 Main()\n{\n  \"Hello from HolyC!\\n\";\n}\n\nMain;\n"
    }
}

/** Incremental HolyC syntax highlighter (per-line color arrays, block-comment state carried over lines). */
class Highlighter(private val lines: List<String>) {
    private val cache = ArrayList<IntArray?>()
    private val startsInComment = ArrayList<Boolean>()

    fun invalidateFrom(r: Int) {
        while (cache.size > r) { cache.removeAt(cache.size - 1); startsInComment.removeAt(startsInComment.size - 1) }
    }

    fun colors(r: Int): IntArray {
        while (cache.size <= r) {
            val i = cache.size
            val inC = if (i == 0) false else endsInComment(i - 1)
            startsInComment.add(inC)
            cache.add(null)
        }
        cache[r]?.let { if (it.size == lines[r].length) return it }
        val c = compute(lines[r], startsInComment[r]).first
        cache[r] = c
        return c
    }

    private fun endsInComment(i: Int) = compute(lines[i], startsInComment[i]).second

    private fun compute(l: String, inComment0: Boolean): Pair<IntArray, Boolean> {
        val c = IntArray(l.length) { Palette.BLUE }
        var inComment = inComment0
        var i = 0
        while (i < l.length) {
            if (inComment) {
                c[i] = Palette.GREEN
                if (l.startsWith("*/", i)) { c[i + 1] = Palette.GREEN; i += 2; inComment = false; continue }
                i++; continue
            }
            val ch = l[i]
            when {
                l.startsWith("//", i) -> { for (j in i until l.length) c[j] = Palette.GREEN; return c to false }
                l.startsWith("/*", i) -> { inComment = true; c[i] = Palette.GREEN; c[i + 1] = Palette.GREEN; i += 2 }
                ch == '"' || ch == '\'' -> {
                    val q = ch; var j = i + 1
                    while (j < l.length && l[j] != q) { if (l[j] == '\\') j++; j++ }
                    for (k in i..minOf(j, l.length - 1)) c[k] = Palette.RED
                    i = j + 1
                }
                ch == '$' -> {
                    val j = l.indexOf('$', i + 1)
                    if (j > i) { for (k in i..j) c[k] = Palette.PURPLE; i = j + 1 } else i++
                }
                ch == '#' -> { var j = i + 1; while (j < l.length && l[j].isLetter()) j++; for (k in i until j) c[k] = Palette.CYAN; i = j }
                ch.isDigit() -> { var j = i; while (j < l.length && (l[j].isLetterOrDigit() || l[j] == '.')) j++; for (k in i until j) c[k] = Palette.BROWN; i = j }
                ch.isLetter() || ch == '_' || ch.code >= 128 -> {
                    var j = i; while (j < l.length && (l[j].isLetterOrDigit() || l[j] == '_' || l[j].code >= 128)) j++
                    val w = l.substring(i, j)
                    val col = when {
                        w in KEYWORDS -> Palette.BLACK
                        w in TYPES -> Palette.PURPLE
                        w.length > 1 && w.all { it.isUpperCase() || it.isDigit() || it == '_' } -> Palette.CYAN
                        else -> Palette.BLUE
                    }
                    for (k in i until j) c[k] = col
                    i = j
                }
                else -> i++
            }
        }
        return c to inComment
    }

    companion object {
        val KEYWORDS = setOf("if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
            "goto", "try", "catch", "throw", "class", "union", "public", "extern", "static", "sizeof", "offset", "start", "end",
            "lock", "no_warn", "reg", "noreg", "asm", "lastclass")
        val TYPES = setOf("U0", "I0", "I8", "U8", "I16", "U16", "I32", "U32", "I64", "U64", "F64", "Bool", "CDC", "CTask",
            "CD3", "CD3I32", "CD2I32", "CD3I64", "CD2I64", "CDate")
    }
}
