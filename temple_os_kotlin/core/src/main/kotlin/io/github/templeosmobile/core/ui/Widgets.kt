package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.kernel.Palette

/**
 * Touch-target sizes in logical px. At the AUTO display scale one logical px is about
 * 1 dp / 1 pt, so the LARGE sizes meet the 48 dp / 44 pt minimum (V-32). The 8x8
 * TempleOS glyphs do not change size; only rows, bars and buttons get taller.
 */
object Touch {
    @Volatile var large = false
    /** Set by the shell while typing in landscape (V-31): there is no room for LARGE sizes. */
    @Volatile var compact = false
    private fun pick(standard: Int, big: Int) = if (large && !compact) big else standard
    val rowH get() = pick(20, 44)
    val topBar get() = pick(20, 40)
    val chrome get() = pick(16, 32)
    val chromeBtn get() = pick(24, 44)
    val keyRow get() = pick(24, 44)
    val header get() = pick(20, 40)
    val editorHeader get() = pick(16, 40)
    val button get() = pick(22, 40)
    val toolRow get() = pick(16, 36)
    /** Row of the TempleOS on-screen keyboard (portrait). */
    val kbdRow get() = pick(34, 44)
}

/**
 * Button faces (design tokens, shared/specifications/templeos-ui/tokens.json). Labels are drawn
 * in face XOR WHITE as TempleOS's CtrlBttn does: LTCYAN gives RED text, LTGREEN gives PURPLE.
 */
object ButtonFace {
    const val NORMAL = Palette.LTCYAN
    const val ACTION = Palette.LTGREEN
    const val SELECTED = Palette.YELLOW
    const val PRESSED = Palette.BLUE
    const val CHARACTER = Palette.WHITE
    const val LOCKED = Palette.RED
    /** Confirm buttons that delete, replace or discard (Delete, Replace, Close unsaved). */
    const val DESTRUCTIVE = Palette.RED
}

/** List row height (logical px). */
val ROW_H get() = Touch.rowH

/** Y offset that centers an 8 px glyph row in a [ROW_H] row. */
val ROW_TEXT get() = (ROW_H - 8) / 2

/**
 * A pull-down menu in TempleOS colors (BLUE background, YELLOW text; the keyboard selection is drawn as
 * TempleOS's DrawMenu draws the entry under the mouse: YELLOW background, BLUE text). Sized by the shell's
 * [MenuMetrics]: glyphs magnified by textScale, rows of touch height, labels wider than the menu wrapped
 * onto more lines. On a short (landscape) viewport a list that does not fit in one column is laid out in
 * columns, row by row; otherwise it scrolls by whole rows (drag, the full-width arrow rows, or keys).
 * A menu opened by another menu's item is its submenu: its title row goes back to [parent].
 */
class PopupMenu(val items: List<MenuItem>, private val ax: Int, private val ay: Int, title: () -> String?, val parent: PopupMenu? = null) {
    private val titleText = L10n.Presentation(title)
    val title get() = titleText.value
    constructor(items: List<MenuItem>, ax: Int, ay: Int, title: String?, parent: PopupMenu? = null) : this(items, ax, ay, { title }, parent)
    private var box = Rect(0, 0, 0, 0)
    /** First visible grid row. */
    var scroll = 0; private set
    /** Keyboard selection (item index), or -1. */
    var selected = -1; private set
    var cols = 1; private set
    private var cellW = 0
    private var gridRows = 0
    private var lines: List<List<String>> = emptyList()
    private var rowLines = IntArray(0)
    private var visibleRows = 0
    private var titleRect: Rect? = null
    private var upRect: Rect? = null
    private var downRect: Rect? = null
    private val cells = ArrayList<Pair<Int, Rect>>()
    private var metrics = MenuMetrics.LEGACY_STANDARD
    val bounds get() = box

    /** Lays the menu out for [sh]'s current geometry and metrics (every draw: rotation never leaves old sizes). */
    private fun layout(s: Surface, sh: Shell) {
        val m = sh.metrics; metrics = m
        val ts = m.textScale
        val left = sh.insetLeft + 4; val right = sh.width - sh.insetRight - 4
        val top = sh.insetTop + 2
        // menus are modal and may cover the TempleOS keyboard (its keys are unusable meanwhile)
        // Leave the shadow plus one content pixel clear of the system edge.
        val bottom = sh.height - maxOf(sh.insetBottom, sh.keyboardHeight) - 5
        val maxW = maxOf(m.charW * 4, right - left)
        val checkW = m.charW + 2 * ts
        val padL = 4 + checkW; val padR = m.padX / 2 + 4
        val titleText = titleLabel()
        val labelW = items.maxOfOrNull { s.measureUi(it.label, ts) } ?: 0
        val titleW = titleText?.let { s.measureUi(it, ts) + 2 * m.padX } ?: 0
        var cw = maxOf(labelW + padL + padR, titleW, 10 * m.charW)
        val titleH = if (titleText != null) m.rowH else 0
        val oneColRows = maxOf(1, (bottom - top - titleH - 8) / m.rowH)
        cols = 1
        if (m.compact && items.size > oneColRows) {
            val fit = maxOf(1, (maxW - 8) / minOf(cw, maxW - 8))
            cols = minOf(fit, (items.size + oneColRows - 1) / oneColRows, 3).coerceAtLeast(1)
        }
        cw = minOf(cw, (maxW - 8) / cols)
        cellW = cw
        val textW = maxOf(m.charW, cw - padL - padR)
        lines = items.map { s.wrapUi(it.label, textW, ts).take(MAX_LINES).ifEmpty { listOf("") } }
        gridRows = (items.size + cols - 1) / cols
        rowLines = IntArray(gridRows) { r -> (0 until cols).maxOf { c -> lines.getOrNull(r * cols + c)?.size ?: 1 } }
        // a menu that fits the screen may move up from its anchor; one that must scroll stays under it
        val total = rowLines.sumOf { m.rowFor(it) }
        val fitsScreen = total <= bottom - top - titleH - 8
        val room = if (fitsScreen) bottom - top - titleH - 8 else bottom - maxOf(top, minOf(ay, bottom - 4 * m.rowH)) - titleH - 8
        val scrolling = !fitsScreen
        val itemRoom = if (scrolling) room - 2 * m.rowH else room
        scroll = scroll.coerceIn(0, maxOf(0, gridRows - 1))
        // the last page: no empty space after the last row
        var lastFirst = gridRows; var acc = 0
        while (lastFirst > 0 && acc + m.rowFor(rowLines[lastFirst - 1]) <= itemRoom) { acc += m.rowFor(rowLines[lastFirst - 1]); lastFirst-- }
        if (scrolling) scroll = scroll.coerceAtMost(lastFirst)
        visibleRows = 0; acc = 0
        while (scroll + visibleRows < gridRows && acc + m.rowFor(rowLines[scroll + visibleRows]) <= maxOf(itemRoom, m.rowFor(rowLines[scroll]))) {
            acc += m.rowFor(rowLines[scroll + visibleRows]); visibleRows++
        }
        val h = 4 + titleH + (if (scrolling) 2 * m.rowH else 0) + acc + 4
        val w = cols * cw + 8
        val x = ax.coerceIn(left, maxOf(left, right - w))
        val y = if (ay + h <= bottom) ay else maxOf(top, bottom - h)  // (only a menu that fits moves up)
        box = Rect(x, y, w, h)
        var cy = y + 4
        titleRect = if (titleText != null) Rect(x, cy, w, titleH).also { cy += titleH } else null
        upRect = if (scrolling) Rect(x, cy, w, m.rowH).also { cy += m.rowH } else null
        cells.clear()
        for (r in scroll until scroll + visibleRows) {
            val rh = m.rowFor(rowLines[r])
            for (c in 0 until cols) {
                val i = r * cols + c
                if (i < items.size) cells.add(i to Rect(x + 4 + c * cw, cy, cw, rh))
            }
            cy += rh
        }
        downRect = if (scrolling) Rect(x, cy, w, m.rowH) else null
    }

    private fun titleLabel(): String? = when {
        parent != null -> "\u0011 " + (title ?: parent.title ?: "")
        else -> title
    }

    fun draw(s: Surface, sh: Shell) {
        layout(s, sh)
        val m = metrics; val ts = m.textScale
        val (x, y, w, h) = box
        s.layer(Rect(x, y, w + 4, h + 4))
        s.fillRect(x + 4, y + 4, w, h, Palette.BLACK) // shadow
        s.fill(box, BG)
        s.frame(box, Palette.YELLOW)
        val rtl = L10n.rtl
        titleRect?.let { r ->
            val t = titleLabel() ?: ""
            s.uiText(r.x + m.padX, m.textTop(r.y, r.h), t, Palette.WHITE, r.w - 2 * m.padX, alignEnd = rtl, scale = ts)
            if (parent != null) sh.a11yButton(r, tr("doc.menu.back") + ": " + (parent.title ?: "")) else sh.a11yText(r, t)
        }
        upRect?.let { r ->
            if (scroll > 0) { s.text(r.x + (r.w - m.charW) / 2, m.textTop(r.y, r.h), "\u0018", Palette.WHITE, scale = ts); sh.a11yButton(r, tr("a11y.scroll_menu_up")) }
            s.hline(r.x + 4, r.right - 5, r.bottom - 1, Palette.LTBLUE)
        }
        val checkW = m.charW + 2 * ts
        for ((i, r) in cells) {
            val it = items[i]
            val sel = i == selected
            if (sel) s.fill(r, Palette.YELLOW)
            val fg = if (!it.enabled) Palette.LTGRAY else if (sel) Palette.BLUE else Palette.YELLOW
            val ls = lines[i]
            val ty = m.textTop(r.y, r.h, ls.size)
            if (it.checked) s.text(if (rtl) r.right - 4 - m.charW else r.x + 4, ty, "\u00FB", if (sel) Palette.GREEN else Palette.LTGREEN, scale = ts)
            val tx = r.x + 4 + checkW; val tw = r.w - 4 - checkW - (m.padX / 2 + 4)
            for ((li, l) in ls.withIndex()) s.uiText(if (rtl) r.x + m.padX / 2 + 4 else tx, ty + li * m.lineH, l, fg, tw, alignEnd = rtl, scale = ts)
            if (it.enabled) sh.a11yButton(r, it.label, it.checked) else sh.a11yText(r, tr("a11y.unavailable", "label" to it.label))
        }
        downRect?.let { r ->
            s.hline(r.x + 4, r.right - 5, r.y, Palette.LTBLUE)
            if (scroll + visibleRows < gridRows) { s.text(r.x + (r.w - m.charW) / 2, m.textTop(r.y, r.h), "\u0019", Palette.WHITE, scale = ts); sh.a11yButton(r, tr("a11y.scroll_menu_down")) }
        }
    }

    /** What a tap at ([x], [y]) is on: an item index, or one of the HIT_ codes. */
    fun hit(x: Int, y: Int): Int {
        if (!box.contains(x, y)) return HIT_OUTSIDE
        titleRect?.let { if (it.contains(x, y)) return if (parent != null) HIT_BACK else HIT_NONE }
        upRect?.let { if (it.contains(x, y)) return if (scroll > 0) HIT_UP else HIT_NONE }
        downRect?.let { if (it.contains(x, y)) return if (scroll + visibleRows < gridRows) HIT_DOWN else HIT_NONE }
        for ((i, r) in cells) if (r.contains(x, y)) return if (items[i].enabled) i else HIT_NONE
        return HIT_NONE
    }

    /** Scrolls by [rows] grid rows (negative: up). Returns true if it moved. */
    fun scrollBy(rows: Int): Boolean {
        val before = scroll
        scroll = (scroll + rows).coerceIn(0, maxOf(0, gridRows - 1))
        return scroll != before
    }

    /** A page: the rows on screen minus one, at least one. */
    val page get() = maxOf(1, visibleRows - 1)

    /** Height of one row step for drag scrolling (logical px). */
    val rowStep get() = metrics.rowH

    /**
     * Keyboard navigation (TempleOS menus are driven by the mouse; external keyboards get arrows): returns
     * the item to run for Enter, [KEY_BACK] for Left/Backspace in a submenu, or -1 when the key was used here.
     */
    fun key(ch: Int, sc: Long): Int {
        val code = (sc and 0x7F).toInt()
        val n = items.size
        if (n == 0) return -1
        fun step(from: Int, d: Int): Int {
            var i = from
            for (k in 0 until n) { i += d; if (i !in 0 until n) return from; if (items[i].enabled) return i }
            return from
        }
        when {
            ch == '\n'.code || ch == ' '.code -> return if (selected in 0 until n && items[selected].enabled) selected else -1
            ch == Keys.CH_BACKSPACE -> return if (parent != null) KEY_BACK else -1
            code == Keys.SC_CURSOR_DOWN -> selected = if (selected < 0) step(-1, 1) else step(selected, cols)
            code == Keys.SC_CURSOR_UP -> selected = if (selected < 0) step(n, -1) else step(selected, -cols)
            code == Keys.SC_CURSOR_RIGHT -> selected = if (selected < 0) step(-1, 1) else if (cols > 1) step(selected, 1) else selected
            code == Keys.SC_CURSOR_LEFT -> {
                if ((selected < 0 || cols == 1 || selected % cols == 0) && parent != null) return KEY_BACK
                if (selected > 0 && cols > 1) selected = step(selected, -1)
            }
            code == Keys.SC_HOME -> selected = step(-1, 1)
            code == Keys.SC_END -> selected = step(n, -1)
            code == Keys.SC_PAGE_DOWN -> selected = step(maxOf(selected, 0) + (page - 1) * cols, cols).coerceAtMost(n - 1)
            code == Keys.SC_PAGE_UP -> selected = step(maxOf(selected, 0) - (page - 1) * cols, -cols).coerceAtLeast(0)
            else -> return -1
        }
        // keep the selection on screen
        if (selected >= 0) {
            val r = selected / cols
            if (r < scroll) scroll = r
            else if (visibleRows > 0 && r >= scroll + visibleRows) scroll = r - visibleRows + 1
        }
        return -1
    }

    companion object {
        /** The menu's background (the color it would show along a screen edge it reached). */
        const val BG = Palette.BLUE
        const val HIT_NONE = -1; const val HIT_UP = -2; const val HIT_DOWN = -3; const val HIT_BACK = -4; const val HIT_OUTSIDE = -5
        const val KEY_BACK = -6
        /** A label wraps onto at most this many lines (the rest is cut, as before at one line). */
        const val MAX_LINES = 3
    }
}

/** Modal dialogs: confirmation, list chooser (program PopUps) and text input. */
class Dialog private constructor(
    title: () -> String,
    message: () -> String,
    items: () -> List<Pair<String, Long>>,
    val itemBg: List<Int>,
    val input: StringBuilder?,
    private val onPick: (Long) -> Unit,
    private val onText: ((String?) -> Unit)?,
) {
    private val titleText = L10n.Presentation(title)
    private val messageText = L10n.Presentation(message)
    private val itemText = L10n.Presentation(items)
    val title get() = titleText.value
    val message get() = messageText.value
    val items get() = itemText.value
    private var box = Rect(0, 0, 0, 0)
    private var scroll = 0
    private var listTop = 0
    private var visible = 0
    private var textScroll = 0
    private var textRows = 0
    private var visibleTextRows = 0
    private var textRect = Rect(0, 0, 0, 0)
    private var textLineH = 12
    private var draggingText = false
    private var downY = 0
    private var dragged = false

    companion object {
        fun confirm(title: String, message: String, ok: String, onOk: () -> Unit) =
            confirm({ title }, { message }, { ok }, onOk)
        fun confirm(title: () -> String, message: () -> String, ok: () -> String, onOk: () -> Unit) =
            Dialog(title, message, { listOf(ok() to 1L, tr("button.cancel") to 0L) }, listOf(-1, -1), null, { if (it == 1L) onOk() }, null)

        /** A confirmation whose OK deletes, replaces or discards: drawn in [ButtonFace.DESTRUCTIVE]. */
        fun confirmDestructive(title: String, message: String, ok: String, onOk: () -> Unit) =
            confirmDestructive({ title }, { message }, { ok }, onOk)
        fun confirmDestructive(title: () -> String, message: () -> String, ok: () -> String, onOk: () -> Unit) =
            Dialog(title, message, { listOf(ok() to 1L, tr("button.cancel") to 0L) }, listOf(DESTRUCTIVE_ROW, -1), null, { if (it == 1L) onOk() }, null)

        /** [itemBg] marker for a destructive choice (other values are colors a program chose). */
        const val DESTRUCTIVE_ROW = -2

        /** The dialog's background (TempleOS PopUp: white). */
        const val BG = Palette.WHITE

        fun choose(title: String, footer: String, items: List<Pair<String, Long>>, bgs: List<Int>, onPick: (Long) -> Unit) =
            choose({ title }, { footer }, { items }, bgs, onPick)
        fun choose(title: () -> String, footer: () -> String, items: () -> List<Pair<String, Long>>, bgs: List<Int>, onPick: (Long) -> Unit) =
            Dialog(title, footer, items, bgs, null, onPick, null)

        fun input(title: String, initial: String, onDone: (String?) -> Unit) =
            input({ title }, initial, onDone)
        fun input(title: () -> String, initial: String, onDone: (String?) -> Unit) =
            Dialog(title, { "" }, { listOf(tr("button.ok") to 1L, tr("button.cancel") to 0L) }, listOf(-1, -1), StringBuilder(initial), {}, onDone)
    }

    val wantsKeyboard get() = input != null

    /** Where the last draw put the dialog (logical px, without its shadow). */
    val bounds get() = box

    /** Called instead of the default cancel result when the dialog is dismissed (Esc, back). */
    var onCancel: (() -> Unit)? = null

    /** Dismisses the dialog without choosing an item. */
    fun cancel() { onCancel?.invoke() ?: finish(if (input != null) 0 else -1) }

    /** Row height of the last layout (the shell's MenuMetrics.rowH): drag and taps use what was drawn. */
    private var rowH = ROW_H

    fun draw(s: Surface, sh: Shell) {
        // TempleOS PopUp look (white, blue double border) at the menu layer's size (MenuMetrics)
        val m = sh.metrics; val ts = m.textScale
        rowH = m.rowH
        val usableW = sh.width - sh.insetLeft - sh.insetRight
        val w = minOf(usableW - 16, maxOf(400, 34 * m.charW + 2 * m.padX))
        val tw = w - 2 * (8 + m.padX / 2)
        val msgLines = wrap(s, message, tw, ts)
        val titleLines = wrap(s, title, tw, ts)
        val lh = m.lineH
        val rtl = L10n.rtl
        val topY = sh.insetTop + sh.barH
        val maxH = sh.height - topY - sh.reservedBottom - 16
        textRows = titleLines.size + msgLines.size
        textLineH = lh
        val chrome = 8 + lh / 2 + (if (input != null) rowH + 8 else 0) + 8
        // Reserve the actions first. Long translations and filenames scroll in their own
        // text viewport instead of pushing Cancel or the confirmation off the screen.
        visible = minOf(items.size, maxOf(1, (maxH - chrome - minOf(textRows, 3) * lh) / rowH))
        visibleTextRows = minOf(textRows, maxOf(0, (maxH - chrome - visible * rowH) / lh))
        val fixed = chrome + visibleTextRows * lh
        val h = fixed + visible * rowH
        val x = sh.insetLeft + (usableW - w) / 2
        val y = topY + maxOf(4, (maxH - h) / 2)
        box = Rect(x, y, w, h)
        s.layer(Rect(x, y, w + 4, h + 4))
        s.fillRect(x + 4, y + 4, w, h, Palette.BLACK)
        s.fill(box, BG)
        s.border(Rect(x, y, w and 7.inv(), h), Palette.BLUE, BG, true)
        val tx = x + 8 + m.padX / 2
        var ty = y + 8 + lh / 2
        textRect = Rect(tx, ty - 2 * ts, tw, visibleTextRows * lh)
        textScroll = textScroll.coerceIn(0, maxOf(0, textRows - visibleTextRows))
        sh.a11yText(textRect, title)
        if (message.isNotBlank()) sh.a11yText(textRect, message)
        val text = titleLines.map { it to Palette.BLUE } + msgLines.map { it to Palette.BLACK }
        s.withClip(textRect) {
            for (i in textScroll until minOf(textRows, textScroll + visibleTextRows)) {
                s.uiText(tx, ty + (i - textScroll) * lh, text[i].first, text[i].second, tw, alignEnd = rtl, scale = ts)
            }
        }
        if (textRows > visibleTextRows && visibleTextRows > 0) {
            val thumb = maxOf(4, textRect.h * visibleTextRows / textRows)
            s.fillRect(textRect.right + 2, textRect.y + (textRect.h - thumb) * textScroll / (textRows - visibleTextRows), 2, thumb, Palette.BLUE)
        }
        ty += visibleTextRows * lh
        if (input != null) {
            ty += 4
            val fr = Rect(x + 10, ty, w - 20, rowH - 4)
            sh.a11yText(fr, tr("a11y.text_field", "text" to InputCharacterPolicy.display(input.toString())))
            s.fill(fr, Palette.LTGRAY)
            val shown = input.toString().takeLast(maxOf(1, (fr.w - 8 - 4 * ts) / m.charW))
            val gy = m.textTop(fr.y, fr.h)
            val ex = s.text(fr.x + 4, gy, shown, Palette.BLACK, scale = ts)
            s.fillRect(ex, gy - ts, 2 * ts, m.glyphH + 2 * ts, Palette.BLUE)
            ty += rowH + 4
        }
        listTop = ty
        scroll = scroll.coerceIn(0, maxOf(0, items.size - visible))
        for (i in scroll until minOf(items.size, scroll + visible)) {
            val ry = ty + (i - scroll) * rowH
            val bg = itemBg.getOrElse(i) { -1 }
            val br = Rect(x + 10, ry + 1, w - 20, rowH - 2)
            if (bg < 0) s.templeButton(br, items[i].first, if (bg == DESTRUCTIVE_ROW) ButtonFace.DESTRUCTIVE else ButtonFace.NORMAL, ts)
            else {
                // a HolyC program chose this row's color (PopUp lists): program content, kept as is
                s.fill(br, bg)
                val fg = if (bg in listOf(0, 1, 4, 5, 6, 8)) Palette.WHITE else Palette.BLACK
                s.uiText(br.x + m.padX / 2, m.textTop(br.y, br.h), items[i].first, fg, br.w - m.padX, alignEnd = rtl, scale = ts)
            }
            sh.a11yButton(Rect(x + 10, ry, w - 20, rowH), items[i].first)
        }
        val ax = x + w - 10 - m.charW - 2
        if (scroll > 0) s.text(ax, m.textTop(listTop, rowH), "\u0018", Palette.BLUE, scale = ts)
        if (scroll + visible < items.size) s.text(ax, m.textTop(listTop + (visible - 1) * rowH, rowH), "\u0019", Palette.BLUE, scale = ts)
    }

    private fun wrap(s: Surface, t: String, maxW: Int, scale: Int): List<String> =
        if (t.isEmpty()) emptyList() else s.wrapUi(t, maxW, scale)

    /** Pointer handling; returns true when the dialog closed. */
    fun pointer(e: PointerEvent, sh: Shell): Boolean {
        when (e.action) {
            Ptr.DOWN -> { downY = e.y; dragged = false; draggingText = textRect.contains(e.x, e.y) }
            Ptr.MOVE -> {
                val dy = e.y - downY
                val step = if (draggingText) textLineH else rowH
                if (Math.abs(dy) >= step) {
                    if (draggingText) textScroll -= dy / step else scroll -= dy / step
                    downY = e.y; dragged = true
                }
            }
            Ptr.UP -> {
                if (dragged) return false
                if (!box.contains(e.x, e.y)) return false
                if (e.y >= listTop) {
                    val i = (e.y - listTop) / rowH + scroll
                    if (i < items.size && i - scroll < visible) { finish(items[i].second); return true }
                }
            }
        }
        return false
    }

    private fun finish(v: Long) {
        if (input != null) onText?.invoke(if (v == 1L) input.toString() else null) else onPick(v)
    }

    /** Keyboard: text entry, Enter = first item, Esc = cancel. */
    fun key(ch: Int, sc: Long, sh: Shell): Boolean {
        when {
            ch == '\n'.code -> { finish(items.firstOrNull()?.second ?: 0); return true }
            ch == Keys.CH_ESC || ch == Keys.CH_SHIFT_ESC -> { cancel(); return true }
            input != null && ch == Keys.CH_BACKSPACE -> { if (input.isNotEmpty()) input.setLength(input.length - 1) }
            input != null && ch in 32..255 -> input.append(ch.toChar())
            (sc and 0x7F).toInt() == Keys.SC_PAGE_DOWN -> textScroll += maxOf(1, visibleTextRows - 1)
            (sc and 0x7F).toInt() == Keys.SC_PAGE_UP -> textScroll -= maxOf(1, visibleTextRows - 1)
            (sc and 0x7F).toInt() == Keys.SC_CURSOR_DOWN -> if (items.size <= visible) textScroll++ else scroll++
            (sc and 0x7F).toInt() == Keys.SC_CURSOR_UP -> if (items.size <= visible) textScroll-- else scroll--
        }
        return false
    }
}
