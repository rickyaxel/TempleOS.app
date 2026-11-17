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

/** How a program's arrow keys are offered (Settings.directional): the four d-pad buttons, or the joystick in their place. */
enum class DirectionalControl { DPAD, JOYSTICK }

class GameControls(private val typematic: Typematic = Typematic(), private val send: (KInput) -> Unit) {
    /**
     * A button. Key buttons ([ch], [sc]) are physical keys: down while held, typematic repeat, up on
     * release (menu shortcuts too: the button stands for the key the menu names). [wheel] buttons turn
     * the mouse wheel one notch per press and repeat; modifier keys never repeat (KbdBuildSC). [dir] is the
     * arrow ([Joystick.UP]...) of a d-pad button or of a joystick push; [touchMode] marks the touch-mode toggle.
     */
    private class Btn(val label: String, val rect: Rect, val ch: Int, val sc: Long, val a11y: String? = null,
                      val toggle: (() -> Unit)? = null, val wheel: Int = 0, val dir: Int = 0, val touchMode: Boolean = false)
    private val buttons = ArrayList<Btn>()
    private val held = HashMap<Int, Btn>()  // hold id (a pointer id, or -arrow for the joystick) -> held button
    private val heldSince = HashMap<Int, Long>() // hold id -> first tick time (-1 until then)
    private val lastRepeat = HashMap<Int, Long>()
    private val ticket = HashMap<Int, Long>()
    /** The joystick, laid out in the d-pad's square in [DirectionalControl.JOYSTICK] mode. */
    val joystick = Joystick()
    /** The finger that drives the joystick (one at a time), and the arrows its push holds. */
    private var stickPointer: Int? = null
    private var stickHeld = 0
    /**
     * The arrow keys the joystick holds, the d-pad's keys. Their hold ids are -[dir]: pointer ids are never
     * negative, so a push and a finger on a button never share an entry.
     */
    private val stickKeys = listOf(Joystick.UP to Keys.SC_CURSOR_UP, Joystick.DOWN to Keys.SC_CURSOR_DOWN,
        Joystick.LEFT to Keys.SC_CURSOR_LEFT, Joystick.RIGHT to Keys.SC_CURSOR_RIGHT).map { (dir, code) ->
        val (c, s) = Keys.special(code); Btn("", Rect(0, 0, 0, 0), c, s, dir = dir)
    }
    /** The joystick toggle asks for the other directional control: the owner keeps it (Settings) and draws with it. */
    var onDirectional: (DirectionalControl) -> Unit = {}
    /** How short a push holds the joystick's arrows ([Joystick.keys]): the owner's setting, read at each push. */
    var stickSensitivity: () -> Int = { Joystick.SENSITIVITY_DEFAULT }
    /**
     * What the layout depends on. While it stays the same, a frame draws the last layout's buttons again instead of
     * building new ones: a held button is the one drawn (PRESSED), and a frame only compares and draws.
     */
    private data class LayoutKey(val r: Rect, val vertical: Boolean, val showDpad: Boolean, val directional: DirectionalControl, val actionArea: Rect?,
                                 val ctrl: Boolean, val shift: Boolean, val wheel: Boolean, val clickMode: Int, val language: Int, val buttonH: Int)
    private var layoutKey: LayoutKey? = null
    /** The menu snapshot the shortcut buttons were read from, and those shortcuts. */
    private var menuSeen: List<MenuSnap> = emptyList()
    private var shortcuts: List<MenuSnap> = emptyList()
    /** Layouts built (tests: frames with nothing new reuse the last one). */
    internal var layouts = 0; private set
    /**
     * The controls' own labels in the UI language (touch modes with their spoken names, wheel) and the widths
     * the layout gives them: resolved when the language changes, not on every frame (the shell's surface
     * measures with one fixed font).
     */
    private class ControlText(s: Surface) {
        val modes = listOf(tr("controls.button.left_click") to tr("controls.a11y.left_click"),
            tr("controls.button.right_click") to tr("controls.a11y.right_click"), tr("controls.button.hover") to tr("controls.a11y.hover"))
        val modeW = modes.maxOf { s.measureUi(it.first) }
        val wheelUp = tr("controls.button.wheel_up")
        val wheelDown = tr("controls.button.wheel_down")
        val wheelUpW = s.measureUi(wheelUp)
        val wheelDownW = s.measureUi(wheelDown)
        val toJoystick = tr("controls.button.joystick")
        val toDpad = tr("controls.button.dpad")
        val directionalW = maxOf(s.measureUi(toJoystick), s.measureUi(toDpad))
        val toJoystickA11y = tr("controls.a11y.joystick_mode")
        val toDpadA11y = tr("controls.a11y.dpad_mode")
        val stickA11y = tr("controls.a11y.joystick")
    }
    private var controlText: L10n.Presentation<ControlText>? = null
    /** What a touch on the picture is: 0 left button, 1 right button, 2 pointer move only (hover). */
    var clickMode = 0
    val rightClick get() = clickMode == 1
    /** Turns the mouse wheel by one notch (BattleLines reads ms.pos.z). */
    var onWheel: (Int) -> Unit = {}

    /**
     * Typematic repeat for held key buttons, like a PC keyboard: TempleOS boots with
     * KbdTypeMatic(0) (HomeLocalize.HC) = 250 ms delay, then 30 key-downs per second.
     * Games that move one step per key message (GetKey: CastleFrankenstein) need it. Returns true while the
     * joystick's knob is easing back to the centre (the controls need drawing).
     */
    fun tick(nowMs: Long): Boolean {
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
        return joystick.settle(nowMs)
    }

    /** The labels of the buttons drawn last, in order (tests, diagnostics). */
    internal val labels get() = buttons.map { it.label }

    /** Screen-reader nodes for the joystick and the buttons drawn last (label, toggle state). */
    fun accessibility(add: (Rect, String, Boolean) -> Unit) {
        controlText?.value?.let { t -> if (joystick.shown) add(joystick.rect, t.stickA11y, false) }
        for (b in buttons) add(b.rect, b.a11y ?: when (b.label) {
            "\u0018" -> tr("key.up"); "\u0019" -> tr("key.down"); "\u001B" -> tr("key.left"); "\u001A" -> tr("key.right")
            "SPACE" -> tr("key.space"); "ENTER" -> tr("key.enter"); "ESC" -> tr("key.escape")
            else -> Cp437.decode(b.label)
        }, b.touchMode && clickMode != 0)
    }

    /**
     * Lays out controls in [r] and draws them into [s]. With [actionArea] (landscape: the gutter right
     * of the picture) the action buttons go there instead of next to the d-pad. A program with the d-pad
     * ([showDpad]) shows it as four buttons or, in [DirectionalControl.JOYSTICK] mode, as the joystick in the
     * same square, and gets the button that switches between them; [directional] never adds either one.
     */
    fun draw(s: Surface, r: Rect, menu: List<MenuSnap>, vertical: Boolean, showDpad: Boolean, directional: DirectionalControl = DirectionalControl.DPAD,
             actionArea: Rect? = null, info: ProgramInfo? = null) {
        val key = LayoutKey(r, vertical, showDpad, directional, actionArea, info?.usesCtrl == true, info?.usesShift == true, info?.usesWheel == true,
            clickMode, L10n.version, Touch.button)
        if (newShortcuts(menu) || key != layoutKey) {
            layout(s, r, vertical, showDpad, directional, actionArea, info)
            layoutKey = key; layouts++
        }
        for (b in buttons) {
            val pressed = held.values.any { it === b }
            val on = b.touchMode && clickMode != 0
            s.templeButton(b.rect, b.label, if (pressed) ButtonFace.PRESSED else if (on) ButtonFace.SELECTED else ButtonFace.NORMAL)
        }
        if (joystick.shown) joystick.draw(s, stickHeld)
    }

    /**
     * Reads the program's menu shortcuts (the menu keys that get a button) when the kernel published a new snapshot:
     * it re-reads the menu every 15 frames, mostly with the same entries. True if the shortcuts changed.
     */
    private fun newShortcuts(menu: List<MenuSnap>): Boolean {
        if (sameEntries(menu, menuSeen)) return false
        menuSeen = menu
        // SPACE, ENTER and ESC have their own buttons, the arrows the d-pad
        val now = menu.filter { !it.isDir && (it.a1 != 0L || it.a2 != 0L) && it.msgCode == -2L }
            .filter { m -> !(m.a1 != 0L && m.a1 in listOf(' '.code.toLong(), '\n'.code.toLong(), Keys.CH_ESC.toLong())) }
            .filter { m -> (m.a2 and 0x7F).toInt() !in listOf(Keys.SC_CURSOR_UP, Keys.SC_CURSOR_DOWN, Keys.SC_CURSOR_LEFT, Keys.SC_CURSOR_RIGHT) }
            .take(6)
        val same = now.size == shortcuts.size && now.indices.all { now[it].label == shortcuts[it].label && now[it].a1 == shortcuts[it].a1 && now[it].a2 == shortcuts[it].a2 }
        shortcuts = now
        return !same
    }

    /** The same snapshot entries (the same objects): what every frame checks, without allocating. */
    private fun sameEntries(a: List<MenuSnap>, b: List<MenuSnap>): Boolean {
        if (a === b) return true
        if (a.size != b.size) return false
        for (i in a.indices) if (a[i] !== b[i]) return false
        return true
    }

    /** Builds the buttons (and places the joystick) for [draw]. */
    private fun layout(s: Surface, r: Rect, vertical: Boolean, showDpad: Boolean, directional: DirectionalControl, actionArea: Rect?, info: ProgramInfo?) {
        buttons.clear()
        if (r.w < 40 || r.h < 40) { hideStick(); return }
        val size = minOf(44, minOf(r.w, r.h) / 3)
        val pad = Rect(r.x + 4, if (vertical) r.y + 4 else r.y + (r.h - size * 3) / 2, size * 3, size * 3)
        val stick = showDpad && directional == DirectionalControl.JOYSTICK
        if (showDpad && !stick) {
            add("\u0018", Rect(pad.x + size, pad.y, size, size), Keys.SC_CURSOR_UP, dir = Joystick.UP)
            add("\u001B", Rect(pad.x, pad.y + size, size, size), Keys.SC_CURSOR_LEFT, dir = Joystick.LEFT)
            add("\u001A", Rect(pad.x + 2 * size, pad.y + size, size, size), Keys.SC_CURSOR_RIGHT, dir = Joystick.RIGHT)
            add("\u0019", Rect(pad.x + size, pad.y + 2 * size, size, size), Keys.SC_CURSOR_DOWN, dir = Joystick.DOWN)
        }
        // a joystick whose square moved under the finger (rotation, a resized window) lets go
        if (stick) { if (joystick.layout(pad) && stickPointer != null) releaseStick() } else hideStick()
        // action buttons: next to the pad, or in [actionArea]
        val actions = ArrayList<Triple<String, Int, Long>>()
        actions.add(Triple("SPACE", ' '.code, Keys.forChar(' '.code).second))
        actions.add(Triple("ENTER", '\n'.code, Keys.special(Keys.SC_ENTER).second))
        actions.add(Triple("ESC", Keys.CH_ESC, Keys.special(Keys.SC_ESC).second))
        val menuKeys = shortcuts
        // keys and mouse parts the program needs that a phone lacks (catalog: source-derived)
        val extras = ArrayList<Btn>()
        if (info?.usesCtrl == true) extras.add(Btn("CTRL", Rect(0, 0, 0, 0), 0, Keys.SC_CTRL.toLong(), tr("key.control")))
        if (info?.usesShift == true) extras.add(Btn("SHIFT", Rect(0, 0, 0, 0), 0, Keys.SC_SHIFT.toLong(), tr("key.shift")))
        val t = (controlText ?: L10n.Presentation { ControlText(s) }.also { controlText = it }).value
        if (info?.usesWheel == true) {
            extras.add(Btn(t.wheelUp, Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_up"), wheel = 1))
            extras.add(Btn(t.wheelDown, Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_down"), wheel = -1))
        }
        val area = actionArea ?: r
        val x0 = if (actionArea != null) area.x + 4 else if (showDpad) pad.right + 8 else r.x + 4
        // a separate gutter holds one or two columns; next to the pad, up to three per row
        val bw = if (actionArea != null) (if (area.w - 4 >= 2 * 56) (area.w - 4) / 2 else area.w - 4).coerceAtMost(96)
            else maxOf(56, (r.w - (if (showDpad) pad.w + 12 else 4)) / 3).coerceAtMost(96)
        var bx = x0
        var by = if (actionArea != null) {
            val count = actions.size + menuKeys.size + extras.size + if (showDpad) 2 else 1
            val rows = (count + maxOf(1, (area.w - 4) / bw) - 1) / maxOf(1, (area.w - 4) / bw)
            area.y + maxOf(4, (area.h - rows * (Touch.button + 4)) / 2)
        } else if (showDpad) pad.y else r.y + 4
        // one grid cell per button; a translated label wider than its cell takes the cells it needs on its row
        fun place(labelW: Int = 0): Rect {
            val w = bw * ((labelW + 8 + bw - 1) / bw).coerceIn(1, maxOf(1, (area.right - x0) / bw))
            if (bx + w > area.right) { bx = x0; by += Touch.button + 4 }
            val rr = Rect(bx, by, w - 4, Touch.button); bx += w; return rr
        }
        for ((l, ch, sc) in actions) add(l, place(), -1, ch, sc)
        for (m in menuKeys) {
            val (ch, sc) = menuKey(m.a1, m.a2)
            buttons.add(Btn(m.label.take(10), place(), ch, sc))
        }
        // CTRL and SHIFT are key caps and keep one cell; a translated wheel label may need more
        for (b in extras) buttons.add(Btn(b.label, place(when (b.wheel) { 1 -> t.wheelUpW; -1 -> t.wheelDownW; else -> 0 }), b.ch, b.sc, b.a11y, wheel = b.wheel))
        // the touch mode's label and spoken name are the app's (translated); the toggle never reads them. Sized
        // for its widest label, so it keeps its place and size while it cycles.
        val (mode, modeA11y) = t.modes[clickMode]
        buttons.add(Btn(mode, place(t.modeW), 0, 0, modeA11y, toggle = { clickMode = (clickMode + 1) % 3 }, touchMode = true))
        // the d-pad/joystick switch is the app's too, named for the mode it switches to; last, so the buttons
        // before it keep their places, and sized for its wider label
        if (showDpad) {
            val next = if (stick) DirectionalControl.DPAD else DirectionalControl.JOYSTICK
            buttons.add(Btn(if (stick) t.toDpad else t.toJoystick, place(t.directionalW), 0, 0, if (stick) t.toDpadA11y else t.toJoystickA11y,
                toggle = { releaseArrows(); onDirectional(next) }))
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

    private fun add(label: String, rect: Rect, scCode: Int, ch: Int = 0, sc: Long = 0, dir: Int = 0) {
        if (scCode >= 0) {
            val (c, s) = Keys.special(scCode)
            buttons.add(Btn(label, rect, c, s, dir = dir))
        } else buttons.add(Btn(label, rect, ch, sc))
    }

    /** [b] goes down for hold id [id]: pressed now, repeated by [tick], up on [release]. */
    private fun hold(id: Int, b: Btn) {
        held[id] = b; heldSince[id] = -1; lastRepeat.remove(id)
        if (b.wheel == 0 && !isModifier(b)) ticket[id] = typematic.pressed()
        press(b)
    }

    /** Lets go of what hold id [id] holds; false if it holds nothing. */
    private fun release(id: Int): Boolean {
        heldSince.remove(id); lastRepeat.remove(id); ticket.remove(id)
        val b = held.remove(id) ?: return false
        if (b.wheel == 0) send(KInput.Key(b.ch, b.sc or Keys.SCF_KEY_UP, false))
        return true
    }

    /** The joystick's finger is at ([x], [y]): the knob follows, and the push holds its arrows. */
    private fun steer(x: Int, y: Int) {
        val (dx, dy) = joystick.push(x, y)
        holdArrows(Joystick.keys(dx, dy, joystick.travel, stickHeld, stickSensitivity()))
    }

    /**
     * Makes the joystick hold exactly the arrows in [bits], as d-pad buttons hold them: the arrows it no
     * longer pushes go up, new ones go down (and become the typematic key); one it keeps is not sent again.
     */
    private fun holdArrows(bits: Int) {
        for (b in stickKeys) if ((stickHeld and b.dir) != 0 && (bits and b.dir) == 0) release(-b.dir)
        for (b in stickKeys) if ((bits and b.dir) != 0 && (stickHeld and b.dir) == 0) hold(-b.dir, b)
        stickHeld = bits
    }

    /** The joystick's finger lifted (or the joystick went away): its arrows go up at once, the knob eases home. */
    private fun releaseStick() {
        holdArrows(0); stickPointer = null; joystick.letGo()
    }

    private fun hideStick() { if (joystick.shown) { releaseStick(); joystick.hide() } }

    /**
     * Switching between the d-pad and the joystick: the arrows either one holds go up, so nothing keeps
     * moving (a finger still on a d-pad button or on the joystick holds nothing more); other keys stay held.
     */
    private fun releaseArrows() {
        for (id in held.filterValues { it.dir != 0 }.keys) release(id)
        stickHeld = 0; stickPointer = null; joystick.center()
    }

    /**
     * Returns true if the pointer hit a control. The joystick follows one finger from anywhere on it until
     * that finger lifts; another finger on it is taken and ignored. Fingers on buttons are independent of it.
     */
    fun pointer(e: PointerEvent): Boolean {
        when (e.action) {
            Ptr.DOWN -> {
                if (joystick.shown && joystick.rect.contains(e.x, e.y)) {
                    if (stickPointer == null) { stickPointer = e.id; steer(e.x, e.y) }
                    return true
                }
                val b = buttons.firstOrNull { it.rect.contains(e.x, e.y) } ?: return false
                if (b.toggle != null) { b.toggle.invoke(); return true }
                hold(e.id, b)
                return true
            }
            Ptr.UP, Ptr.CANCEL -> {
                if (e.id == stickPointer) { releaseStick(); return true }
                return release(e.id)
            }
            Ptr.MOVE -> {
                if (e.id == stickPointer) { steer(e.x, e.y); return true }
                return held.containsKey(e.id)
            }
        }
        return false
    }

    /**
     * The current layout has no control area (landscape gutters under 96 px, console view): forget the
     * last layout's buttons. They are hit-tested before the picture, so leftovers were invisible keys and
     * a tap beside the picture could send Abort (Shift-Esc) and end the program. Held keys stay held
     * until their finger lifts; the joystick lets go (there is no joystick without the control area).
     */
    fun clearLayout() { buttons.clear(); hideStick(); layoutKey = null }

    /** Releases everything (focus loss, rotation) so no key stays stuck. */
    fun releaseAll() {
        for (b in held.values) if (b.wheel == 0) send(KInput.Key(b.ch, b.sc or Keys.SCF_KEY_UP, false))
        held.clear(); heldSince.clear(); lastRepeat.clear()
        stickHeld = 0; stickPointer = null; joystick.letGo()
    }

    companion object {
        const val REPEAT_DELAY_MS = 250L
        const val REPEAT_PERIOD_MS = 33L
    }

    val anyHeld get() = held.isNotEmpty()
}

/**
 * The joystick that can take the d-pad's place ([GameControls], Settings.directional): a stick drawn in
 * TempleOS colors and pixels in the pad's square. It keeps the geometry, the picture and the knob; a push
 * ([keys]) becomes the arrow keys the d-pad buttons hold, through the same key path.
 */
class Joystick {
    /** The square it fills: the pad's, one pixel less when even, so its crosshair and knob have a centre pixel. */
    var rect = Rect(0, 0, 0, 0); private set
    val shown get() = rect.w > 0
    val cx get() = rect.x + rect.w / 2
    val cy get() = rect.y + rect.h / 2
    /** How far the knob's centre moves from the centre. */
    var travel = 1; private set
    /** The knob's offset from the centre. */
    var knobX = 0; private set
    var knobY = 0; private set
    private var returnX = 0
    private var returnY = 0
    private var returnAt = 0L
    private var returning = false
    private var knob = 0
    /** The picture as rows of one color (built once per size, drawn as filled spans). */
    private class Run(val x: Int, val y: Int, val w: Int, val kind: Int)
    private var art: List<Run> = emptyList()
    private var knobArt: List<Run> = emptyList()

    /** Places it in the d-pad's square [pad]; returns true when it moved or changed size. */
    fun layout(pad: Rect): Boolean {
        val s = minOf(pad.w, pad.h)
        val d = if (s % 2 == 1) s else s - 1
        val r = Rect(pad.x + (pad.w - d) / 2, pad.y + (pad.h - d) / 2, d, d)
        if (r == rect) return false
        if (d != rect.w) build(d)
        rect = r
        return true
    }

    fun hide() { rect = Rect(0, 0, 0, 0); center() }

    fun center() { knobX = 0; knobY = 0; returning = false }

    /** A finger at ([x], [y]): the knob goes as far towards it as it travels. Returns the push from the centre. */
    fun push(x: Int, y: Int): Pair<Int, Int> {
        returning = false
        val dx = x - cx; val dy = y - cy; val q = dx * dx + dy * dy
        if (q <= travel * travel) { knobX = dx; knobY = dy } else {
            val f = travel.toDouble() / Math.sqrt(q.toDouble())
            knobX = round(dx * f); knobY = round(dy * f)
        }
        return dx to dy
    }

    /** The finger let go: the knob eases back to the centre ([settle]). */
    fun letGo() { if (knobX != 0 || knobY != 0) { returnX = knobX; returnY = knobY; returnAt = -1; returning = true } }

    /** Moves a returning knob on; true while it moves (and once more when it arrives). */
    fun settle(nowMs: Long): Boolean {
        if (!returning) return false
        if (returnAt < 0) returnAt = nowMs
        val f = 1.0 - (nowMs - returnAt).toDouble() / RETURN_MS
        if (f <= 0) { center(); return true }
        knobX = round(returnX * f); knobY = round(returnY * f)
        return true
    }

    /** The rim lights up on the side of each arrow the push holds. */
    fun draw(s: Surface, keys: Int) {
        for (r in art) s.fillRect(rect.x + r.x, rect.y + r.y, r.w, 1, color(r.kind, keys))
        val kx = cx + knobX - knob / 2; val ky = cy + knobY - knob / 2
        for (r in knobArt) s.fillRect(kx + r.x, ky + r.y, r.w, 1, color(r.kind, keys))
    }

    /**
     * Draws the picture for diameter [d] (odd) in whole pixels, with integer arithmetic only (the same pixels on
     * every platform). Coordinates are doubled, from the centre pixel: X = 2x + 1 - d.
     */
    private fun build(d: Int) {
        val rim = if (d >= 100) 3 else if (d >= 60) 2 else 1
        knob = maxOf(7, (d * 2 / 5) or 1)
        travel = maxOf(1, d / 2 - rim - knob / 2 - 1)
        val inner = d - 2 * rim; val marks = inner - 6; val guide = 2 * travel
        art = runs(d) { x, y ->
            val q = x * x + y * y
            when {
                q >= d * d -> -1
                q >= inner * inner -> RIM or (if (Math.abs(x) > Math.abs(y)) (if (x < 0) LEFT else RIGHT) else if (y < 0) UP else DOWN)
                (x == 0 || y == 0) && q < marks * marks -> {
                    // the crosshair: a solid centre, then dashes out to the rim
                    val along = (Math.abs(x) + Math.abs(y)) / 2
                    if (along <= 3) MARK else if ((along / 3) % 2 == 0) GUIDE else BASE
                }
                // the ring the knob's centre can reach, dashed
                q >= (guide - 1) * (guide - 1) && q < (guide + 1) * (guide + 1) && (minOf(Math.abs(x), Math.abs(y)) / 8) % 2 == 0 -> GUIDE
                else -> BASE
            }
        }
        val k = knob; val shift = 2 * maxOf(1, k / 12)
        knobArt = runs(k) { x, y ->
            val q = x * x + y * y
            when {
                q >= k * k -> -1
                q >= (k - 2) * (k - 2) -> KNOB_EDGE
                // flat, with a shaded crescent down-right in whole pixels
                (x + shift) * (x + shift) + (y + shift) * (y + shift) >= (k - 2) * (k - 2) -> KNOB_SHADE
                else -> KNOB
            }
        }
    }

    companion object {
        /** Arrow bits (a d-pad button's or a push's [GameControls] dir). */
        const val UP = 1; const val DOWN = 2; const val LEFT = 4; const val RIGHT = 8
        /**
         * The sensitivity levels (Settings.joystickSensitivity): the higher, the shorter the push that holds keys.
         * The default needs twice the push of [SENSITIVITY_MAX].
         */
        const val SENSITIVITY_MIN = 1; const val SENSITIVITY_MAX = 5; const val SENSITIVITY_DEFAULT = 3
        /**
         * A push holds keys from [engagePercent] of the knob's travel and lets go below [releasePercent], so a thumb
         * resting at the edge of the dead zone does not chatter. Each arrow takes [CARDINAL] degrees either side of
         * its axis, a diagonal (two arrows) the 30 degrees between, and a held direction stays until the push is
         * [STICKY] degrees past its edge.
         */
        const val CARDINAL = 30.0; const val STICKY = 6.0
        /** Percent of the knob's travel a push needs to hold keys at [sensitivity]: 90, 75, 60, 45, 30. */
        fun engagePercent(sensitivity: Int) = 105 - 15 * sensitivity.coerceIn(SENSITIVITY_MIN, SENSITIVITY_MAX)
        /** Percent of the knob's travel below which a held push lets go: 66, 55, 44, 33, 22. */
        fun releasePercent(sensitivity: Int) = engagePercent(sensitivity) * 11 / 15
        /** How long the released knob takes back to the centre (its keys go up at once). */
        const val RETURN_MS = 80L
        /** Counter-clockwise from right, 45 degrees apart. */
        private val SECTORS = intArrayOf(RIGHT, UP or RIGHT, UP, UP or LEFT, LEFT, DOWN or LEFT, DOWN, DOWN or RIGHT)

        /**
         * The arrow keys a push of ([dx], [dy]) from the centre holds (y grows downwards) for a knob that travels
         * [travel] px, given the keys [held] now: none in the dead zone ([sensitivity] sets its size), else one
         * arrow, or two on a diagonal, as two fingers on the d-pad hold them.
         */
        fun keys(dx: Int, dy: Int, travel: Int, held: Int, sensitivity: Int = SENSITIVITY_DEFAULT): Int {
            // the dead zone's edge in whole numbers (percent of the travel): the same pixel on every platform
            val edge = (if (held == 0) engagePercent(sensitivity) else releasePercent(sensitivity)).toLong() * maxOf(1, travel)
            if ((dx.toLong() * dx + dy.toLong() * dy) * 10000 < edge * edge) return 0
            var a = Math.atan2(-dy.toDouble(), dx.toDouble()) * 180 / Math.PI
            if (a < 0) a += 360
            fun apart(b: Double): Double { val d = Math.abs(a - b) % 360; return if (d > 180) 360 - d else d }
            val i = SECTORS.indexOf(held)
            if (i >= 0 && apart(i * 45.0) <= (if (i % 2 == 0) CARDINAL else 45 - CARDINAL) + STICKY) return held
            val axis = Math.floor(a / 90 + 0.5).toInt() % 4
            return if (apart(axis * 90.0) <= CARDINAL) SECTORS[axis * 2] else SECTORS[(a / 90).toInt() % 4 * 2 + 1]
        }

        /** Halves round up, as on every platform (the knob lands on the same pixel). */
        private fun round(v: Double) = Math.floor(v + 0.5).toInt()

        // what a pixel of the picture is: the base, its guide marks, the rim (by quadrant: RIM or an arrow), the knob
        private const val BASE = 0; private const val GUIDE = 1; private const val MARK = 2; private const val RIM = 16
        private const val KNOB = 32; private const val KNOB_SHADE = 33; private const val KNOB_EDGE = 34

        private fun color(kind: Int, keys: Int) = when (kind) {
            BASE -> Palette.BLACK
            GUIDE -> Palette.CYAN
            MARK, KNOB -> Palette.LTCYAN
            KNOB_SHADE -> Palette.CYAN
            KNOB_EDGE -> Palette.WHITE
            else -> if ((keys and (kind and 15)) != 0) Palette.LTCYAN else Palette.CYAN
        }

        /** Run-length encodes a [d] x [d] picture whose pixel at doubled offset (X, Y) is [kind] (-1: none). */
        private fun runs(d: Int, kind: (Int, Int) -> Int): List<Run> {
            val out = ArrayList<Run>()
            for (y in 0 until d) {
                var x = 0
                while (x < d) {
                    val k = kind(2 * x + 1 - d, 2 * y + 1 - d)
                    var e = x + 1
                    while (e < d && kind(2 * e + 1 - d, 2 * y + 1 - d) == k) e++
                    if (k >= 0) out.add(Run(x, y, e - x, k))
                    x = e
                }
            }
            return out
        }
    }
}

/** Largest 4:3 rectangle centred in [r] (programs keep their 640x480 aspect). */
fun fit43(r: Rect): Rect = fitAspect(r, 4, 3)

/** Largest rectangle of aspect [aw]:[ah] centred in [r] (a program window keeps its shape). */
fun fitAspect(r: Rect, aw: Int, ah: Int): Rect {
    var w = r.w; var h = (w.toLong() * ah / maxOf(1, aw)).toInt()
    if (h > r.h) { h = r.h; w = (h.toLong() * aw / maxOf(1, ah)).toInt() }
    return Rect(r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h)
}
