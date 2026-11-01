package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.*

/** KernelEnv for kernels hosted in the shell. Callbacks arrive on kernel threads. */
class UiKernelEnv(private val shell: Shell, private val ownerFocused: () -> Boolean) : KernelEnv {
    override fun runtimeFile(name: String) = shell.env.runtimeFile(name)
    override val fs: VirtualFs get() = shell.env.fs
    override val memoryLimit: Int get() = shell.env.memoryLimitBytes

    /** This program's speaker setting, audible or not (guarded by [mux]). */
    private var hz = 0.0
    /** Whether this program owns the speaker: sound is on, its window has the focus, it is not paused (UI thread). */
    private var audible = false
    @Volatile private var paused = false
    private val mux = shell.speaker

    /** UI thread, every tick: re-reads the setting, the focus and the pause, and claims or releases the speaker. */
    fun refresh() {
        val now = shell.settings.sound && !paused && ownerFocused()
        if (now == audible) return
        audible = now
        synchronized(mux) { if (now) mux.claim(this, hz) else mux.release(this) }
    }

    override fun sound(kernel: Kernel, freq: Double, atNs: Long) {
        synchronized(mux) { hz = freq; mux.set(this, freq, atNs) }
    }
    override fun paused(kernel: Kernel, paused: Boolean) { this.paused = paused; refresh() }
    override fun openEditor(kernel: Kernel, path: String) = shell.post { if (ownerFocused()) Launch.editor(shell, path) }
    override fun openDocument(kernel: Kernel, path: String) = shell.post { if (ownerFocused()) Launch.doc(shell, path) }
    override fun popupRequested(kernel: Kernel, req: PopupRequest) = shell.post {
        fun answer(value: Long) { if (kernel.popup === req) kernel.answerPopup(value) else req.result = value }
        if (!ownerFocused() || kernel.popup !== req) { answer(-1); return@post }
        // texts come from the HolyC program (CP437 bytes): shown as the program wrote them
        shell.showDialog(Dialog.choose( { if (req.header.isBlank()) tr("dialog.choose") else Cp437.decode(req.header) }, { Cp437.decode(req.footer) }, { req.items.map { Cp437.decode(it.label) to it.value } }, req.items.map { it.bg }) { v -> answer(v) }.also { it.onCancel = { answer(-1) } })
    }
}

/**
 * The device has one speaker, like the PC. TempleOS lets any task set it; here the program whose window
 * has the focus owns it ([UiKernelEnv.refresh]). Kernel threads change their program's setting, the UI
 * thread moves the ownership; one lock orders both, so a window losing the focus never silences the one
 * that took it, and a new owner's current setting (a held note) sounds at once.
 */
class SpeakerMux(private val env: ShellEnv) {
    private var owner: Any? = null
    @Synchronized fun claim(who: Any, hz: Double) { if (owner !== who) { owner = who; env.tone(hz, System.nanoTime()) } }
    @Synchronized fun release(who: Any) { if (owner === who) { owner = null; env.tone(0.0, System.nanoTime()) } }
    @Synchronized fun set(who: Any, hz: Double, atNs: Long) { if (owner === who) env.tone(hz, atNs) }
}

/** Frame source over a kernel's published 640x480 screen. */
class KernelFrame(private val k: Kernel) : FrameSource {
    override val frameW = Kernel.W
    override val frameH = Kernel.H
    override val frameVersion get() = k.publishedVersion
    override val palette get() = k.palette
    override fun copyFrame(dst: ByteArray): Long = synchronized(k.publishLock) {
        System.arraycopy(k.published, 0, dst, 0, minOf(dst.size, k.published.size))
        k.publishedVersion
    }
    override val window: Rect get() = synchronized(k.publishLock) { k.publishedWindow.let { Rect(it[0], it[1], it[2], it[3]) } }
}

/**
 * Maps a touch at ([x], [y]) in [canvas] (which shows [window] of the 640x480 screen) to screen
 * pixels, as TempleOS's mouse reports them (ms.pos is screen-absolute).
 */
fun canvasToScreen(x: Int, y: Int, canvas: Rect, window: Rect): Pair<Int, Int> {
    val sx = window.x + (x - canvas.x) * window.w / maxOf(1, canvas.w)
    val sy = window.y + (y - canvas.y) * window.h / maxOf(1, canvas.h)
    return sx.coerceIn(window.x, window.right - 1) to sy.coerceIn(window.y, window.bottom - 1)
}

/** Draws a kernel console (TempleOS document) into a rect with scrollback. */
class ConsoleView {
    var scrollBack = 0
    private var cells = IntArray(0)

    fun draw(s: Surface, r: Rect, console: Console, showCursor: Boolean) {
        val cols = maxOf(1, r.w / 8); val rows = maxOf(1, r.h / 8)
        if (cells.size < cols * rows) cells = IntArray(cols * rows)
        val blank = (Console.DFT_BG shl 4) or Console.DFT_FG
        val total = console.visualRows(cols)
        scrollBack = scrollBack.coerceIn(0, maxOf(0, total - rows))
        console.renderCells(cells, cols, rows, blank, scrollBack)
        s.fill(r, Palette.WHITE)
        for (row in 0 until rows) for (c in 0 until cols) {
            val cell = cells[row * cols + c]
            s.cell(r.x + c * 8, r.y + row * 8, cell)
        }
        if (showCursor && scrollBack == 0 && console.cursorVisible) {
            // find the last non-blank row to place the cursor after the text
            var lastRow = 0
            for (row in rows - 1 downTo 0) {
                if ((0 until cols).any { (cells[row * cols + it] and 0xFF) != ' '.code }) { lastRow = row; break }
            }
            var col = 0
            for (c in cols - 1 downTo 0) if ((cells[lastRow * cols + c] and 0xFF) != ' '.code) { col = c + 1; break }
            if (col >= cols) col = cols - 1
            if ((System.currentTimeMillis() / 500) % 2 == 0L) s.fillRect(r.x + col * 8, r.y + lastRow * 8 + 7, 8, 1, Palette.BLUE)
        }
        if (scrollBack > 0) {
            val t = " \u0018 $scrollBack "
            s.text(r.right - t.length * 8, r.y, t, Palette.WHITE, Palette.RED)
        }
    }

    fun scrollBy(rowsDelta: Int) { scrollBack = maxOf(0, scrollBack + rowsDelta) }
}

/**
 * Touch controls for a running program: a d-pad (arrow keys, held while
 * pressed), action keys, and the program's own menu actions (TempleOS menus
 * carry key bindings, e.g. "Accelerator(,,SC_CURSOR_UP)").
 */
/**
 * A PC keyboard has one typematic key: the key pressed last repeats, and once it is released no key
 * repeats until another is pressed (PS/2 typematic; TempleOS only sees the repeated make codes). One
 * per shell, shared by the physical keyboard, the TempleOS keyboard and the game buttons.
 */
class Typematic {
    private var seq = 0L
    /** A key went down: it becomes the typematic key. Returns its ticket. */
    fun pressed(): Long = ++seq
    fun repeats(ticket: Long) = ticket == seq
}

class GameControls(private val typematic: Typematic = Typematic(), private val send: (KInput) -> Unit) {
    /**
     * A button. Key buttons ([ch], [sc]) are physical keys: down while held, typematic repeat, up on
     * release (menu shortcuts too: the button stands for the key the menu names). [wheel] buttons turn
     * the mouse wheel one notch per press and repeat; modifier keys never repeat (KbdBuildSC).
     */
    private class Btn(val label: String, val rect: Rect, val ch: Int, val sc: Long, val a11y: String? = null,
                      val toggle: (() -> Unit)? = null, val wheel: Int = 0)
    private val buttons = ArrayList<Btn>()
    private val held = HashMap<Int, Btn>()  // pointer id -> held button
    private val heldSince = HashMap<Int, Long>() // pointer id -> first tick time (-1 until then)
    private val lastRepeat = HashMap<Int, Long>()
    private val ticket = HashMap<Int, Long>()
    /** What a touch on the picture is: 0 left button, 1 right button, 2 pointer move only (hover). */
    var clickMode = 0
    val rightClick get() = clickMode == 1
    /** Turns the mouse wheel by one notch (BattleLines reads ms.pos.z). */
    var onWheel: (Int) -> Unit = {}

    /**
     * Typematic repeat for held key buttons, like a PC keyboard: TempleOS boots with
     * KbdTypeMatic(0) (HomeLocalize.HC) = 250 ms delay, then 30 key-downs per second.
     * Games that move one step per key message (GetKey: CastleFrankenstein) need it.
     */
    fun tick(nowMs: Long) {
        for ((id, b) in held) {
            if (b.toggle != null || isModifier(b)) continue
            if (b.wheel == 0 && !typematic.repeats(ticket[id] ?: -1)) continue
            val since = heldSince[id] ?: continue
            if (since < 0) { heldSince[id] = nowMs; lastRepeat[id] = nowMs + REPEAT_DELAY_MS - REPEAT_PERIOD_MS; continue }
            if (nowMs - since < REPEAT_DELAY_MS) continue
            var last = lastRepeat[id] ?: since
            var n = 0
            while (nowMs - last >= REPEAT_PERIOD_MS && n++ < 2) { press(b); last += REPEAT_PERIOD_MS }
            if (nowMs - last >= REPEAT_PERIOD_MS) last = nowMs // do not queue a burst after a stall
            lastRepeat[id] = last
        }
    }

    /** Screen-reader nodes for the buttons drawn last (label, toggle state). */
    fun accessibility(add: (Rect, String, Boolean) -> Unit) {
        for (b in buttons) add(b.rect, b.a11y ?: when (b.label) {
            "\u0018" -> tr("key.up"); "\u0019" -> tr("key.down"); "\u001B" -> tr("key.left"); "\u001A" -> tr("key.right")
            "SPACE" -> tr("key.space"); "ENTER" -> tr("key.enter"); "ESC" -> tr("key.escape")
            "L-CLICK" -> tr("controls.a11y.left_click"); "R-CLICK" -> tr("controls.a11y.right_click"); "MOVE" -> tr("controls.a11y.hover")
            else -> Cp437.decode(b.label)
        }, b.toggle != null && clickMode != 0)
    }

    /**
     * Lays out controls in [r] and draws them into [s]. With [actionArea] (landscape: the gutter right
     * of the picture) the action buttons go there instead of next to the d-pad.
     */
    fun draw(s: Surface, r: Rect, menu: List<MenuSnap>, vertical: Boolean, showDpad: Boolean, actionArea: Rect? = null,
             info: ProgramInfo? = null) {
        buttons.clear()
        if (r.w < 40 || r.h < 40) return
        val size = minOf(44, minOf(r.w, r.h) / 3)
        val pad = Rect(r.x + 4, if (vertical) r.y + 4 else r.y + (r.h - size * 3) / 2, size * 3, size * 3)
        if (showDpad) {
            add("\u0018", Rect(pad.x + size, pad.y, size, size), Keys.SC_CURSOR_UP)
            add("\u001B", Rect(pad.x, pad.y + size, size, size), Keys.SC_CURSOR_LEFT)
            add("\u001A", Rect(pad.x + 2 * size, pad.y + size, size, size), Keys.SC_CURSOR_RIGHT)
            add("\u0019", Rect(pad.x + size, pad.y + 2 * size, size, size), Keys.SC_CURSOR_DOWN)
        }
        // action buttons: next to the pad, or in [actionArea]
        val actions = ArrayList<Triple<String, Int, Long>>()
        actions.add(Triple("SPACE", ' '.code, Keys.forChar(' '.code).second))
        actions.add(Triple("ENTER", '\n'.code, Keys.special(Keys.SC_ENTER).second))
        actions.add(Triple("ESC", Keys.CH_ESC, Keys.special(Keys.SC_ESC).second))
        val menuKeys = menu.filter { !it.isDir && (it.a1 != 0L || it.a2 != 0L) && it.msgCode == -2L }
            .filter { m -> actions.none { it.second.toLong() == m.a1 && m.a1 != 0L } }
            .filter { m -> (m.a2 and 0x7F).toInt() !in listOf(Keys.SC_CURSOR_UP, Keys.SC_CURSOR_DOWN, Keys.SC_CURSOR_LEFT, Keys.SC_CURSOR_RIGHT) }
            .take(6)
        // keys and mouse parts the program needs that a phone lacks (catalog: source-derived)
        val extras = ArrayList<Btn>()
        if (info?.usesCtrl == true) extras.add(Btn("CTRL", Rect(0, 0, 0, 0), 0, Keys.SC_CTRL.toLong(), tr("key.control")))
        if (info?.usesShift == true) extras.add(Btn("SHIFT", Rect(0, 0, 0, 0), 0, Keys.SC_SHIFT.toLong(), tr("key.shift")))
        if (info?.usesWheel == true) {
            extras.add(Btn("WHL+", Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_up"), wheel = 1))
            extras.add(Btn("WHL-", Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_down"), wheel = -1))
        }
        val area = actionArea ?: r
        val x0 = if (actionArea != null) area.x + 4 else if (showDpad) pad.right + 8 else r.x + 4
        // a separate gutter holds one or two columns; next to the pad, up to three per row
        val bw = if (actionArea != null) (if (area.w - 4 >= 2 * 56) (area.w - 4) / 2 else area.w - 4).coerceAtMost(96)
            else maxOf(56, (r.w - (if (showDpad) pad.w + 12 else 4)) / 3).coerceAtMost(96)
        var bx = x0
        var by = if (actionArea != null) {
            val count = actions.size + menuKeys.size + extras.size + 1
            val rows = (count + maxOf(1, (area.w - 4) / bw) - 1) / maxOf(1, (area.w - 4) / bw)
            area.y + maxOf(4, (area.h - rows * (Touch.button + 4)) / 2)
        } else if (showDpad) pad.y else r.y + 4
        fun place(): Rect {
            if (bx + bw > area.right) { bx = x0; by += Touch.button + 4 }
            val rr = Rect(bx, by, bw - 4, Touch.button); bx += bw; return rr
        }
        for ((l, ch, sc) in actions) add(l, place(), -1, ch, sc)
        for (m in menuKeys) {
            val (ch, sc) = menuKey(m.a1, m.a2)
            buttons.add(Btn(m.label.take(10), place(), ch, sc))
        }
        for (b in extras) buttons.add(Btn(b.label, place(), b.ch, b.sc, b.a11y, wheel = b.wheel))
        buttons.add(Btn(when (clickMode) { 1 -> "R-CLICK"; 2 -> "MOVE"; else -> "L-CLICK" }, place(), 0, 0,
            toggle = { clickMode = (clickMode + 1) % 3 }))
        for (b in buttons) {
            val pressed = held.values.any { it === b }
            val on = b.toggle != null && clickMode != 0
            s.templeButton(b.rect, b.label, if (pressed) ButtonFace.PRESSED else if (on) ButtonFace.SELECTED else ButtonFace.NORMAL)
        }
    }

    /**
     * The key a menu shortcut names (Adam/Menu.HC entries carry arg1 = ASCII, arg2 = scan code; many
     * give only the ASCII): a button is that key, so it gets the key's scan code for kbd.down_bitmap.
     */
    private fun menuKey(a1: Long, a2: Long): Pair<Int, Long> = when {
        a2 != 0L -> a1.toInt() to a2
        a1 == Keys.CH_SHIFT_ESC.toLong() -> Keys.special(Keys.SC_ESC, shift = true)
        a1 in 1L..255L -> Keys.forChar(a1.toInt())
        else -> a1.toInt() to a2
    }

    private fun isModifier(b: Btn) = (b.sc and 0xFF).toInt().let { it == Keys.SC_CTRL || it == Keys.SC_SHIFT || it == Keys.SC_ALT }

    private fun press(b: Btn) { if (b.wheel != 0) onWheel(b.wheel) else send(KInput.Key(b.ch, b.sc, true)) }

    private fun add(label: String, rect: Rect, scCode: Int, ch: Int = 0, sc: Long = 0) {
        if (scCode >= 0) {
            val (c, s) = Keys.special(scCode)
            buttons.add(Btn(label, rect, c, s))
        } else buttons.add(Btn(label, rect, ch, sc))
    }

    /** Returns true if the pointer hit a control. */
    fun pointer(e: PointerEvent): Boolean {
        when (e.action) {
            Ptr.DOWN -> {
                val b = buttons.firstOrNull { it.rect.contains(e.x, e.y) } ?: return false
                if (b.toggle != null) { b.toggle.invoke(); return true }
                held[e.id] = b; heldSince[e.id] = -1; lastRepeat.remove(e.id)
                if (b.wheel == 0 && !isModifier(b)) ticket[e.id] = typematic.pressed()
                press(b)
                return true
            }
            Ptr.UP, Ptr.CANCEL -> {
                heldSince.remove(e.id); lastRepeat.remove(e.id); ticket.remove(e.id)
                val b = held.remove(e.id) ?: return false
                if (b.wheel == 0) send(KInput.Key(b.ch, b.sc or Keys.SCF_KEY_UP, false))
                return true
            }
            Ptr.MOVE -> return held.containsKey(e.id)
        }
        return false
    }

    /**
     * The current layout has no control area (landscape gutters under 96 px, console view): forget the
     * last layout's buttons. They are hit-tested before the picture, so leftovers were invisible keys and
     * a tap beside the picture could send Abort (Shift-Esc) and end the program. Held keys stay held
     * until their finger lifts.
     */
    fun clearLayout() = buttons.clear()

    /** Releases everything (focus loss, rotation) so no key stays stuck. */
    fun releaseAll() {
        for (b in held.values) if (b.wheel == 0) send(KInput.Key(b.ch, b.sc or Keys.SCF_KEY_UP, false))
        held.clear(); heldSince.clear(); lastRepeat.clear()
    }

    companion object {
        const val REPEAT_DELAY_MS = 250L
        const val REPEAT_PERIOD_MS = 33L
    }

    val anyHeld get() = held.isNotEmpty()
}

/** Largest 4:3 rectangle centred in [r] (programs keep their 640x480 aspect). */
fun fit43(r: Rect): Rect = fitAspect(r, 4, 3)

/** Largest rectangle of aspect [aw]:[ah] centred in [r] (a program window keeps its shape). */
fun fitAspect(r: Rect, aw: Int, ah: Int): Rect {
    var w = r.w; var h = (w.toLong() * ah / maxOf(1, aw)).toInt()
    if (h > r.h) { h = r.h; w = (h.toLong() * aw / maxOf(1, ah)).toInt() }
    return Rect(r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h)
}
