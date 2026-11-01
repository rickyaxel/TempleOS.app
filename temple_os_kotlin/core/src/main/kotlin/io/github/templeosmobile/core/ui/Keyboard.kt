package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.kernel.Palette

/**
 * The in-app TempleOS keyboard (UI normalization pass). The shell draws it in the TempleOS
 * palette and 8x8 font with TempleOS's own button look ([templeButton]) and sends exactly what
 * a hardware keyboard sends: (ch, scan code) pairs through [Shell.key]. The editor, terminal,
 * dialogs and HolyC programs therefore handle caret, selection and undo as before.
 * All software input is application-owned; CP437 opens the extended-character picker.
 */
class TempleKeyboard(private val shell: Shell) {
    /** A key: [w] in tenths of a row; [ch] a character, else [sc] a special scan code or an [action]. */
    class Key(val label: String, val w: Int = 10, val ch: Char = '\u0000', val sc: Int = 0, val action: Int = 0, val a11y: String = label)

    var layer = LETTERS
        private set
    /** 0 off, 1 next key only, 2 caps lock. */
    var shift = 0
        private set
    private var lastShiftTap = 0L

    /** Keys held by each pointer id, and when they were pressed / last repeated. */
    private val held = HashMap<Int, Key>()
    private val heldAt = HashMap<Int, Long>()
    private val repeatedAt = HashMap<Int, Long>()
    /** Typematic tickets of raw (PC keyboard) presses: only the key pressed last repeats. */
    private val rawTicket = HashMap<Int, Long>()
    private val keyRects = ArrayList<Pair<Rect, Key>>()

    companion object {
        const val LETTERS = 0; const val SYMBOLS = 1; const val FUNCTIONS = 2
        const val A_SHIFT = 1; const val A_CTRL = 2; const val A_ALT = 3; const val A_SYM = 4; const val A_FN = 5
        const val A_HIDE = 6; const val A_EXT = 7
        const val REPEAT_DELAY_MS = 400L
        const val REPEAT_MS = 60L

        private fun chars(s: String, w: Int = 10) = s.map { Key(it.toString(), w, ch = it) }
        private fun sp(label: String, sc: Int, w: Int = 10, a11y: String = label) = Key(label, w, sc = sc, a11y = a11y)
        private fun act(label: String, a: Int, w: Int = 10, a11y: String = label) = Key(label, w, action = a, a11y = a11y)

        private val CHAR_NAMES = mapOf(' ' to "space", '"' to "quote", '\'' to "apostrophe", '`' to "backtick", ';' to "semicolon",
            ':' to "colon", ',' to "comma", '.' to "period", '(' to "left_parenthesis", ')' to "right_parenthesis",
            '{' to "left_brace", '}' to "right_brace", '[' to "left_bracket", ']' to "right_bracket", '<' to "less_than",
            '>' to "greater_than", '=' to "equals", '+' to "plus", '-' to "minus", '_' to "underscore", '/' to "slash",
            '\\' to "backslash", '|' to "vertical_bar", '~' to "tilde", '!' to "exclamation_mark", '@' to "at",
            '#' to "number_sign", '$' to "dollar", '%' to "percent", '^' to "caret", '&' to "ampersand", '*' to "asterisk",
            '?' to "question_mark")

        /** Spoken name of a character key (letters and digits speak themselves). */
        fun a11yName(c: Char) = CHAR_NAMES[c]?.let { tr("char.$it") } ?: c.toString()

        val TOP = listOf(
            sp("ESC", Keys.SC_ESC, a11y = "key.escape"), sp("TAB", Keys.SC_TAB, a11y = "key.tab"),
            act("CTRL", A_CTRL, a11y = "key.control"), act("ALT", A_ALT, a11y = "key.alt"),
            sp("\u001B", Keys.SC_CURSOR_LEFT, a11y = "key.left"), sp("\u0018", Keys.SC_CURSOR_UP, a11y = "key.up"),
            sp("\u0019", Keys.SC_CURSOR_DOWN, a11y = "key.down"), sp("\u001A", Keys.SC_CURSOR_RIGHT, a11y = "key.right"),
            act("EXT", A_EXT, a11y = "CP437"), act("HIDE", A_HIDE, a11y = "key.hide_keyboard"),
        )
        private val BKSP = sp("BKSP", Keys.SC_BACKSPACE, 15, "key.backspace")
        private fun bottom(toggle: String, toggleA11y: String) = listOf(
            act(toggle, A_SYM, 15, toggleA11y), act("FN", A_FN, a11y = "key.function_keys"),
        ) + chars("()") + listOf(sp("SPACE", Keys.SC_SPACE, 20, "key.space")) + chars(",.") +
            listOf(sp("ENTER", Keys.SC_ENTER, 15, "key.enter"))

        private val LETTER_ROWS = listOf(
            chars("1234567890"),
            chars("qwertyuiop"),
            chars("asdfghjkl;\"", 9),
            listOf(act("SHIFT", A_SHIFT, 15, "key.shift")) + chars("zxcvbnm") + BKSP,
            bottom("SYM", "key.symbols"),
        )
        private val SYMBOL_ROWS = listOf(
            chars("1234567890"),
            chars("!@#$%^&*-+"),
            chars("{}[]<>=_/\\"),
            listOf(sp("DEL", Keys.SC_DELETE, 15, "key.delete")) + chars("|'`~:?", 11) + BKSP,
            bottom("ABC", "key.letters"),
        )
        private val FUNCTION_ROWS = listOf(
            (1..10).map { sp("F$it", Keys.SC_F1 + it - 1) },
            listOf(sp("F11", 0x57, 12), sp("F12", 0x58, 12), sp("HOME", Keys.SC_HOME, 13, "key.home"), sp("END", Keys.SC_END, 12, "key.end"),
                sp("PGUP", Keys.SC_PAGE_UP, 13, "key.page_up"), sp("PGDN", Keys.SC_PAGE_DOWN, 13, "key.page_down"),
                sp("INS", Keys.SC_INS, 12, "key.insert"), sp("DEL", Keys.SC_DELETE, 13, "key.delete")),
            LETTER_ROWS[2], LETTER_ROWS[3], bottom("SYM", "key.symbols"),
        )
    }

    fun rows(): List<List<Key>> = listOf(TOP) + when (layer) {
        SYMBOLS -> SYMBOL_ROWS; FUNCTIONS -> FUNCTION_ROWS; else -> LETTER_ROWS
    }

    /** Row height in logical px: smaller in landscape, where height is scarce. */
    fun rowHeight(): Int = if (shell.landscape) 26 else Touch.kbdRow

    fun height(): Int = rows().size * rowHeight() + 4

    /** Clears one-shot state (focus change, keyboard hidden, program closed). */
    fun reset() {
        for (id in rawDown.keys.toList()) rawRelease(id)
        setShift(0); layer = LETTERS
        held.clear(); heldAt.clear(); repeatedAt.clear(); textDown.clear()
    }

    private fun shifted(c: Char): Char {
        if (shift == 0) return c
        if (c.isLetter()) return c.uppercaseChar()
        val i = "1234567890-=[];'`\\,./".indexOf(c)
        return if (i >= 0) "!@#$%^&*()_+{}:\"~|<>?"[i] else c
    }

    private fun label(k: Key): String = if (k.ch != '\u0000') shifted(k.ch).toString() else when (k.action) {
        A_SHIFT -> if (shift == 2) "CAPS" else "SHIFT"
        else -> k.label
    }

    private fun face(k: Key, pressed: Boolean): Int = when {
        pressed -> ButtonFace.PRESSED
        k.action == A_SHIFT && shift == 2 -> ButtonFace.LOCKED
        (k.action == A_SHIFT && shift == 1) || (k.action == A_CTRL && shell.ctrlLatched) || (k.action == A_ALT && shell.altLatched) -> ButtonFace.SELECTED
        (k.action == A_SYM && layer == SYMBOLS) || (k.action == A_FN && layer == FUNCTIONS) -> ButtonFace.SELECTED
        k.sc == Keys.SC_ENTER -> ButtonFace.ACTION
        k.ch != '\u0000' || k.sc == Keys.SC_SPACE -> ButtonFace.CHARACTER
        else -> ButtonFace.NORMAL
    }

    fun draw(s: Surface, r: Rect) {
        keyRects.clear()
        s.fillRect(r.x, r.y, r.w, r.h, Palette.BLACK)
        val rh = rowHeight()
        val pressed = held.values.toSet()
        for ((ri, row) in rows().withIndex()) {
            val total = row.sumOf { it.w }
            var acc = 0
            val y = r.y + 2 + ri * rh
            for (k in row) {
                val x0 = r.x + acc * r.w / total
                acc += k.w
                val x1 = r.x + acc * r.w / total
                val kr = Rect(x0, y, x1 - x0, rh)
                s.templeButton(kr, label(k), face(k, k in pressed))
                keyRects.add(kr to k)
                shell.a11yButton(kr, if (k.ch != '\u0000') a11yName(shifted(k.ch)) else if (k.a11y.startsWith("key.")) tr(k.a11y) else k.a11y,
                    selected = face(k, false) == ButtonFace.SELECTED || face(k, false) == ButtonFace.LOCKED)
            }
        }
    }

    private fun keyAt(x: Int, y: Int): Key? = keyRects.firstOrNull { it.first.contains(x, y) }?.second

    /**
     * True while a running TempleOS program has the focus: then this is a PC keyboard for it (a key
     * goes down when touched and up when released, and repeats at TempleOS's own rate), so programs
     * that test kbd.down_bitmap (RainDrops' valves, Strut's thrusters, Psalmody's organ) can hold
     * keys. For text (editor, terminal, dialogs) keys commit on release.
     */
    private fun raw() = shell.dialogOpen.not() && shell.focused?.app?.rawKeys == true

    /** Keys sent down in raw mode, per pointer. */
    private val rawDown = HashMap<Int, Pair<Int, Long>>()
    private val textDown = HashMap<Int, Pair<Int, Long>>()

    /** Pointer inside the keyboard: keys commit on release and repeat while held (raw: down/up). */
    fun pointer(e: PointerEvent, now: Long) {
        val raw = raw()
        when (e.action) {
            Ptr.DOWN -> keyAt(e.x, e.y)?.let {
                held[e.id] = it; heldAt[e.id] = now; repeatedAt.remove(e.id)
                if (raw && it.action == 0) rawPress(e.id, it)
                else if (it.action == 0) textDown[e.id] = keyCode(it).let { pair -> shell.resolvedKey(pair.first, pair.second) }
            }
            Ptr.MOVE -> {
                val k = keyAt(e.x, e.y)
                if (k != null && k !== held[e.id] && e.id in held) {
                    held[e.id] = k; heldAt[e.id] = now; repeatedAt.remove(e.id)
                    if (!raw && k.action == 0) textDown[e.id] = keyCode(k).let { shell.resolvedKey(it.first, it.second) }
                    if (rawDown.containsKey(e.id)) { rawRelease(e.id); if (k.action == 0) rawPress(e.id, k) }
                }
            }
            Ptr.UP -> {
                val k = held.remove(e.id)
                val text = textDown.remove(e.id)
                val repeated = repeatedAt.remove(e.id) != null
                heldAt.remove(e.id)
                if (rawDown.containsKey(e.id)) rawRelease(e.id)
                else if (k != null && !(raw && k.action == 0)) {
                    if (k.action == 0) {
                        if (!repeated && text != null) { shell.key(text.first, text.second, true); shell.key(text.first, text.second or Keys.SCF_KEY_UP, false) }
                        if (shift == 1) setShift(0)
                    } else if (!repeated) press(k, now)
                }
            }
            Ptr.CANCEL -> { held.remove(e.id); heldAt.remove(e.id); repeatedAt.remove(e.id); textDown.remove(e.id); if (rawDown.containsKey(e.id)) rawRelease(e.id) }
        }
        shell.invalidate()
    }

    private fun keyCode(k: Key): Pair<Int, Long> =
        if (k.ch != '\u0000') Keys.forChar(shifted(k.ch).code) else Keys.special(k.sc, shift = shift != 0)

    private fun rawPress(id: Int, k: Key) {
        val (ch, sc) = keyCode(k)
        rawDown[id] = ch to sc
        rawTicket[id] = shell.typematic.pressed()
        shell.key(ch, sc, true)
    }

    private fun rawRelease(id: Int) {
        rawTicket.remove(id)
        val (ch, sc) = rawDown.remove(id) ?: return
        shell.key(ch, sc or Keys.SCF_KEY_UP, false)
        if (shift == 1) setShift(0)
    }

    private fun repeats(k: Key) = k.action == 0 && k.sc != Keys.SC_ENTER && k.sc != Keys.SC_ESC && k.sc != Keys.SC_TAB

    /** Typematic repeat for held keys; true if something was typed. */
    fun tick(now: Long): Boolean {
        var any = false
        for ((id, k) in held.toList()) {
            val since = heldAt[id] ?: continue
            val last = repeatedAt[id]
            val down = rawDown[id]
            if (down != null) {
                if (!shell.typematic.repeats(rawTicket[id] ?: -1)) continue
                // TempleOS typematic (HomeLocalize.HC KbdTypeMatic(0)): 250 ms, then 30 key-downs per second
                if ((last == null && now - since >= Shell.TYPEMATIC_DELAY_MS) || (last != null && now - last >= Shell.TYPEMATIC_PERIOD_MS)) {
                    shell.key(down.first, down.second, true); repeatedAt[id] = now; any = true
                }
                continue
            }
            if (!repeats(k)) continue
            if ((last == null && now - since >= REPEAT_DELAY_MS) || (last != null && now - last >= REPEAT_MS)) {
                textDown[id]?.let { shell.key(it.first, it.second, true); shell.key(it.first, it.second or Keys.SCF_KEY_UP, false) }
                repeatedAt[id] = now; any = true
            }
        }
        return any
    }

    /** SHIFT state; a running program sees the SHIFT key go down and up with it. */
    private fun setShift(v: Int) {
        val was = shift != 0
        shift = v
        if (was != (v != 0) && raw()) shell.shiftLatch(v != 0)
    }

    private fun press(k: Key, now: Long) {
        when (k.action) {
            A_SHIFT -> {
                // tap: next key only; second tap within 400 ms: caps lock; tap again: off
                setShift(when {
                    shift == 1 && now - lastShiftTap < 400 -> 2
                    shift == 0 -> 1
                    else -> 0
                })
                lastShiftTap = now
            }
            A_CTRL -> shell.toggleCtrl()
            A_ALT -> shell.toggleAlt()
            A_SYM -> layer = if (layer == SYMBOLS) LETTERS else SYMBOLS
            A_FN -> layer = if (layer == FUNCTIONS) LETTERS else FUNCTIONS
            A_HIDE -> shell.hideKeyboard()
            A_EXT -> shell.showCharacterPicker()
            else -> {
                // SHIFT applies to special keys too: SHIFT-ESC (abort), SHIFT-F1..F12, SHIFT-arrows
                val (ch, sc) = keyCode(k)
                shell.key(ch, sc, true); shell.key(ch, sc or Keys.SCF_KEY_UP, false)
                if (shift == 1) setShift(0)
            }
        }
        shell.invalidate()
    }
}

/**
 * TempleOS's own button look (Adam/Ctrls/CtrlsBttn.HC, DrawCtrlBttn): a BLACK rectangle,
 * the face color inset by 2 px, and the label centered in face XOR WHITE.
 */
fun Surface.templeButton(r: Rect, label: String, face: Int, scale: Int = 1) {
    fillRect(r.x, r.y, r.w, r.h, Palette.BLACK)
    fillRect(r.x + 2, r.y + 2, maxOf(0, r.w - 4), maxOf(0, r.h - 4), face)
    // a label too wide for its button at [scale] is drawn at the font's own size instead of being cut
    val k = if (scale > 1 && (measureUi(label, scale) > r.w - 4 || 8 * scale > r.h - 4)) 1 else scale
    val w = minOf(measureUi(label, k), r.w - 4)
    uiText(r.x + (r.w - w) / 2, r.y + (r.h - 8 * k) / 2, label, face xor Palette.WHITE, r.w - 4, scale = k)
}
