package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.kernel.*
import java.util.concurrent.ConcurrentLinkedQueue

/** Services the platform provides to the shell. */
interface ShellEnv {
    /** System runtime files ("Prelude.HC", "PreludeDefines.HC", "GrLib.HC", "KernelClasses.HC", "font8x8.bin"). */
    fun runtimeFile(name: String): ByteArray?
    val fs: LayeredFs
    /** Directory for session state (outside the user's C: drive). */
    val stateStore: StateStore
    fun nowMs(): Long = System.currentTimeMillis()
    /** CPU time this process has used (all threads), ns; -1 when the platform cannot tell (benchmarks). */
    fun processCpuNs(): Long = -1L
    /**
     * The device's PC speaker: [freq] Hz from [atNs] (System.nanoTime) until the next call, 0 = off
     * (kernel/PcSpeaker.kt renders it; docs/audio/TEMPLEOS_SOUND.md).
     */
    fun tone(freq: Double, atNs: Long = System.nanoTime()) {}
    fun clipboardGet(): String? = null
    fun clipboardSet(s: String) {}
    /** User-selected About action; opens only Brand.PRIVACY_URL, never a program-supplied URL. */
    fun openPrivacyPolicy() {}
    /** Ask the platform to show or hide the soft keyboard. */
    /** Invoked from any thread when the shell needs rendering. */
    fun requestRender() {}
    /** The device's (or this app's) preferred UI languages, most preferred first (BCP-47 tags). */
    fun preferredLanguages(): List<String> = listOf("en-US")
    /** The device's region setting (ISO 3166 code), used only to pick a variant of a language. */
    fun deviceRegion(): String? = null
    /** Width in logical px of [s] drawn by the platform's text engine (see [Surface.TextRun]). */
    fun measureText(s: String): Int = s.length * 8
    val memoryLimitBytes: Int get() = 32 shl 20
    /** The platform's minimum touch target in dp/pt (Material 48 dp, Apple HIG 44 pt): sizes menu rows. */
    val touchTargetDp: Double get() = 48.0
}

/** Small key-value persistence for the session (platform file or preferences). */
interface StateStore {
    fun load(): String?
    fun save(text: String)
}

/**
 * The TempleOS Mobile desktop: a window manager drawing TempleOS-style windows
 * into a logical framebuffer. Landscape shows overlapping windows like the
 * original desktop; portrait shows one window at a time with a window deck.
 *
 * All methods must be called on the UI thread. Kernels run on their own
 * threads and talk to the shell through queues.
 */
class Shell(val env: ShellEnv) {
    /** The one speaker the program windows share ([UiKernelEnv]). */
    val speaker = SpeakerMux(env)
    val font: ByteArray = env.runtimeFile("font8x8.bin") ?: error("font missing")
    val surface = Surface(320, 480, font).also {
        it.measureNative = { s -> env.measureText(s) }
        L10n.init(env::runtimeFile)
    }
    val fs get() = env.fs

    /** The effective UI language: the in-app choice, else the device's, else English. */
    val uiLocale get() = L10n.locale

    /** Re-resolves the UI language (settings changed, device language changed); keeps all state. */
    fun applyLanguage() {
        val r = L10n.resolver ?: return
        val (id, _) = r.resolve(settings.language.ifEmpty { null }, env.preferredLanguages(), env.deviceRegion())
        val before = L10n.version
        L10n.use(id)
        if (L10n.version != before) { windows.forEach { it.app.dirty = true }; invalidate() }
    }

    var width = 320; private set
    var height = 480; private set
    val landscape get() = width > height
    /** Safe-area insets and keyboard height, in logical pixels. */
    var insetTop = 0; private set
    var insetBottom = 0; private set
    var insetLeft = 0; private set
    var insetRight = 0; private set
    var keyboardHeight = 0; private set
    /** dp (Android) or pt (iOS) per logical px: display scale / density, from the platform view. */
    var dpPerPx = 1.0; private set

    class Window(val app: App) {
        var x = 0; var y = 0; var w = 0; var h = 0
        var maximized = false
        /** Last visibility reported to the app (null = not reported yet). */
        var shownState: Boolean? = null
        val id = nextId++
        companion object { var nextId = 1 }
    }

    val windows = ArrayList<Window>()
    var focused: Window? = null; private set
    private var needsRender = true
    private val uiQueue = ConcurrentLinkedQueue<() -> Unit>()

    // overlays (menus, dialogs)
    private var menu: PopupMenu? = null
    private var dialog: Dialog? = null
    private var toast: L10n.Presentation<String>? = null
    private var toastUntil = 0L

    /** UI-thread frame pacing reported by the platform view (perf log). */
    val uiFrames = UiFrameStats()

    val catalog: Catalog by lazy { Catalog.load(this) }
    val historicalMenus: HistoricalMenus by lazy {HistoricalMenus.load(this)}
    var settings = Settings().also { Touch.large = it.largeTouch }
        set(v) { field = v; Touch.large = v.largeTouch }

    // ------------------------------------------------------------ lifecycle

    fun invalidate() { needsRender = true; env.requestRender() }

    init { applyLanguage() }

    /** Runs [f] on the UI thread at the next tick (safe from kernel threads). */
    /** User override from the key row's keyboard key: 1 force shown, -1 force hidden (until focus changes). */
    private var keyboardOverride = 0

    /** The only software keyboard; independent of Android text input. */
    val keyboard = TempleKeyboard(this)

    /** True while the TempleOS keyboard is on screen. */
    var templeKeyboardShown = false
        private set

    /** Re-shows the keyboard (e.g. a tap in a text area after the user dismissed it). */
    fun requestKeyboard() { keyboardOverride = 1; syncKeyboard() }

    /** Hides the on-screen keyboard until a text area is tapped or focus changes. */
    fun hideKeyboard() { keyboardOverride = -1; syncKeyboard() }

    /** Compatibility hook: hardware use does not change software keyboard intent. */
    fun hardwareKeyUsed() {} // Hardware use never withdraws the only software keyboard.

    // ------------------------------------------------------------ physical keyboards

    /** The one key that repeats, across the physical keyboard, the TempleOS keyboard and game buttons. */
    val typematic = Typematic()

    private class HeldKey(val ch: Int, val sc: Long, val since: Long, val ticket: Long, var last: Long = 0)
    private val heldHw = LinkedHashMap<Int, HeldKey>()

    /**
     * A physical key (Android KeyEvent, iOS UIPress), down or up. TempleOS repeats a held key at its
     * own typematic rate (HomeLocalize.HC KbdTypeMatic(0): 250 ms, then 30 per second) and never repeats
     * SHIFT/CTRL/ALT (Kernel/SerialDev/Keyboard.HC KbdBuildSC), so the platform's repeats are dropped
     * and [tick] repeats. Modifier keys are keys of their own for a running program (Titanium reads
     * Bt(kbd.down_bitmap,SC_CTRL)); other apps only see their flags on the other keys.
     */
    fun hardwareKey(ch: Int, sc: Long, down: Boolean, platformRepeat: Boolean = false) {
        if (platformRepeat || !inputActive) return
        val code = (sc and 0xFF).toInt()
        if (isModifierCode(code)) {
            if (down) {
                if (code in heldHw) return
                heldHw[code] = HeldKey(ch, sc, env.nowMs(), -1)
            } else if (heldHw.remove(code) == null) return
            val app = focused?.app
            if (dialog == null && menu == null && app?.rawKeys == true) {
                val flag = when (code) { Keys.SC_SHIFT -> Keys.SCF_SHIFT; Keys.SC_CTRL -> Keys.SCF_CTRL; else -> Keys.SCF_ALT }
                app.key(ch, if (down) sc else (sc and flag.inv()) or Keys.SCF_KEY_UP, down)
            }
            return
        }
        if (down) {
            if (heldHw.containsKey(code)) return
            heldHw[code] = HeldKey(ch, sc, env.nowMs(), typematic.pressed())
            key(ch, sc, true)
        } else {
            val held = heldHw.remove(code) ?: return
            key(held.ch, held.sc or Keys.SCF_KEY_UP, false)
        }
    }

    /** Lifts every held physical key (focus change, background) so none stays down in a program. */
    fun releaseHardwareKeys() {
        val held = heldHw.values.toList(); heldHw.clear()
        for (h in held) key(h.ch, (h.sc and (Keys.SCF_SHIFT or Keys.SCF_CTRL or Keys.SCF_ALT).inv()) or Keys.SCF_KEY_UP, false)
    }

    private fun repeatHardwareKeys(now: Long) {
        for (h in heldHw.values.toList()) {
            if (isModifierCode((h.sc and 255).toInt()) || !typematic.repeats(h.ticket)) continue
            if (now - h.since < TYPEMATIC_DELAY_MS) continue
            if (h.last == 0L) h.last = h.since + TYPEMATIC_DELAY_MS - TYPEMATIC_PERIOD_MS
            var n = 0
            while (now - h.last >= TYPEMATIC_PERIOD_MS && n++ < 2) { key(h.ch, h.sc, true); h.last += TYPEMATIC_PERIOD_MS }
            if (now - h.last >= TYPEMATIC_PERIOD_MS) h.last = now // no burst after a stall
        }
    }

    private fun isModifierCode(code: Int) = code == Keys.SC_SHIFT || code == Keys.SC_CTRL || code == Keys.SC_ALT

    /**
     * The on-screen CTRL/ALT latches for a running program: TempleOS sees the key go down when it is
     * latched and up when the latch ends ("sticky keys"), so held-key checks see it.
     */
    private fun latchEvent(code: Int, down: Boolean) {
        val app = focused?.app ?: return
        if (dialog != null || menu != null || !app.rawKeys) return
        val flag = when (code) { Keys.SC_CTRL -> Keys.SCF_CTRL; Keys.SC_ALT -> Keys.SCF_ALT; else -> Keys.SCF_SHIFT }
        app.key(0, if (down) code.toLong() or flag else code.toLong() or Keys.SCF_KEY_UP, down)
    }

    /** Compatibility for old callers: software input is always owned by TempleOS. */
    fun setKeyboardMode(mode: Int) { settings.keyboardMode = Settings.KEYBOARD_TEMPLEOS; syncKeyboard(); saveSession() }

    private fun keyboardWanted() = dialog?.wantsKeyboard == true || when (keyboardOverride) {
        1 -> true; -1 -> false; else -> focused?.app?.wantsKeyboard == true
    }

    /** Shows or hides the TempleOS or device keyboard to match what the dialog / focused app needs. */
    private fun syncKeyboard() {
        val want = keyboardWanted()
        val tos = want
        if (tos != templeKeyboardShown) {
            templeKeyboardShown = tos
            if (!tos) keyboard.reset()
            relayout(false); windows.forEach { it.app.dirty = true }; invalidate()
        }
    }

    /** Height kept free at the bottom: home indicator / device keyboard, plus the TempleOS keyboard. */
    val reservedBottom get() = insetBottom + (if (templeKeyboardShown) keyboard.height() else 0)

    // accessibility nodes recorded while rendering (see [A11yNode])
    private val a11yBase = ArrayList<A11yNode>()
    private val a11yKeys = ArrayList<A11yNode>()
    private val a11yModal = ArrayList<A11yNode>()
    private var a11yTarget = a11yBase

    /** Records a tappable element for TalkBack / VoiceOver; called while drawing. */
    fun a11yButton(r: Rect, label: String, selected: Boolean = false) { if (label.isNotBlank()) a11yTarget.add(A11yNode(r, label, true, selected)) }

    /** Records readable text for TalkBack / VoiceOver; called while drawing. */
    fun a11yText(r: Rect, label: String) { if (label.isNotBlank()) a11yTarget.add(A11yNode(r, label, false)) }

    /** What a screen reader can reach now: a dialog or menu is modal; keyboard keys stay reachable. */
    fun accessibilityNodes(): List<A11yNode> = (if (a11yModal.isNotEmpty()) a11yModal else a11yBase) + a11yKeys

    /** Increases whenever [accessibilityNodes] may have changed (each render). */
    var a11yVersion = 0L
        private set

    /** Performs a screen reader's activation: a tap at the node's center. */
    fun accessibilityActivate(n: A11yNode) {
        val x = n.rect.x + n.rect.w / 2; val y = n.rect.y + n.rect.h / 2
        val t = env.nowMs()
        pointer(PointerEvent(Ptr.DOWN, x, y, A11Y_POINTER, t))
        pointer(PointerEvent(Ptr.UP, x, y, A11Y_POINTER, t + 1))
        tick()
    }

    fun post(f: () -> Unit) { uiQueue.add(f); env.requestRender() }

    fun resize(w: Int, h: Int, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0, keyboard: Int = 0, dpPerPx: Double = this.dpPerPx) {
        val wasLandscape = landscape
        width = maxOf(w, 160); height = maxOf(h, 160)
        insetTop = top; insetBottom = bottom; insetLeft = left; insetRight = right; keyboardHeight = 0
        if (dpPerPx.isFinite() && dpPerPx > 0) this.dpPerPx = dpPerPx
        syncCompact()
        surface.resize(width, height)
        if (wasLandscape != landscape) relayout(true) else relayout(false)
        windows.forEach { it.app.dirty = true }
        invalidate()
    }

    /** Re-lays out the windows with the current [Touch] sizes (Settings change). */
    fun relayout() = resize(width, height, insetTop, insetBottom, insetLeft, insetRight, keyboardHeight)

    // ------------------------------------------------------------ menu layer sizes

    private var mmCache: MenuMetrics? = null
    private var mmKey = LongArray(6)

    /**
     * Sizes of the menu layer for the current usable viewport ([MenuMetrics.compute]): recomputed when the
     * size, insets, keyboard, display scale, touch setting or typing layout change (rotation, split screen),
     * so a menu opened after a rotation never has the old sizes.
     */
    val metrics: MenuMetrics get() {
        val uw = width - insetLeft - insetRight
        val uh = height - insetTop - insetBottom
        val k0 = uw.toLong(); val k1 = uh.toLong(); val k2 = dpPerPx.toRawBits()
        val k3 = if (Touch.large) 1L else 0L; val k4 = if (typingCompact) 1L else 0L; val k5 = env.touchTargetDp.toRawBits()
        val c = mmCache
        if (c != null && mmKey[0] == k0 && mmKey[1] == k1 && mmKey[2] == k2 && mmKey[3] == k3 && mmKey[4] == k4 && mmKey[5] == k5) return c
        mmKey[0] = k0; mmKey[1] = k1; mmKey[2] = k2; mmKey[3] = k3; mmKey[4] = k4; mmKey[5] = k5
        return MenuMetrics.compute(uw, uh, dpPerPx, env.touchTargetDp, Touch.large, typingCompact).also { mmCache = it }
    }

    /** Height of the top bar (0 while typing in landscape, when it is hidden). */
    val barH get() = metrics.barH
    private val chromeH get() = metrics.chromeH
    private val chromeBtnW get() = metrics.chromeBtnW
    /** Width of the window menu button (glyph and label) in a window's menu row. */
    private fun menuBtnW(w: Window): Int {
        val m = metrics
        return minOf(maxOf(8, w.w - 16 - 3 * m.chromeBtnW), 8 + 3 * m.charW + surface.measureUi(tr("window.menu"), m.textScale) + m.charW)
    }

    /** Desktop area (below the top bar, above the bottom bar / keyboard). */
    fun desktopRect(): Rect {
        val top = insetTop + topBarH
        val bottom = height - insetBottom - bottomBarHeight()
        return Rect(insetLeft, top, width - insetLeft - insetRight, maxOf(40, bottom - top))
    }

    /** The TempleOS keyboard when shown, else the key row for text apps. */
    private fun bottomBarHeight(): Int = if (templeKeyboardShown) keyboard.height() else if (focusedWantsKeyRow()) KEY_ROW else 0

    /**
     * Where floating (landscape, not maximized) windows are placed and kept: the desktop
     * without the soft keyboard, so showing the keyboard does not shrink them for good (V-31).
     */
    private fun floatRect(): Rect {
        val top = insetTop + barH
        // neither keyboard counts (device or TempleOS): only the key row a text app always has
        val bottom = height - insetBottom - (if (focusedWantsKeyRow()) KEY_ROW else 0)
        return Rect(insetLeft, top, width - insetLeft - insetRight, maxOf(40, bottom - top))
    }

    /**
     * V-31: in landscape the soft keyboard leaves very little height (about 90 logical px on
     * a phone). While it is up for a text app, that app fills the space with no window frame,
     * the top bar is hidden and STANDARD sizes are used. The key row's keyboard key hides the
     * keyboard and brings everything back; window geometry is not changed.
     */
    val typingCompact get() = landscape && (templeKeyboardShown) && focusedWantsKeyRow()

    private val topBarH get() = if (typingCompact) 0 else barH

    private fun borderless(w: Window) = w === focused && typingCompact

    /** Keeps [Touch.compact] in step with [typingCompact]; called at every entry point. */
    private fun syncCompact() { Touch.compact = typingCompact }

    private fun focusedWantsKeyRow() = focused?.app?.wantsKeyboard == true

    private fun relayout(orientationChanged: Boolean) {
        val d = desktopRect()
        for ((i, win) in windows.withIndex()) {
            if (!landscape || win.maximized || win.w == 0 || orientationChanged) {
                if (landscape && !win.maximized) placeNew(win, i) else { win.x = d.x; win.y = d.y; win.w = d.w; win.h = d.h }
            }
            clampWindow(win)
        }
    }

    private fun placeNew(win: Window, index: Int) {
        val d = floatRect()
        val w = minOf(d.w, maxOf(320, d.w * 2 / 3)) and 7.inv()
        val h = minOf(d.h, maxOf(200, d.h * 3 / 4)) and 7.inv()
        val off = (index % 6) * 16
        win.x = d.x + minOf(off, d.w - w); win.y = d.y + minOf(off, d.h - h); win.w = w; win.h = h
    }

    private fun clampWindow(win: Window) {
        if (!landscape || win.maximized) { val d = desktopRect(); win.x = d.x; win.y = d.y; win.w = d.w; win.h = d.h; return }
        val d = floatRect()
        win.w = win.w.coerceIn(minOf(160, d.w), d.w); win.h = win.h.coerceIn(minOf(96, d.h), d.h)
        win.x = win.x.coerceIn(d.x, d.right - win.w); win.y = win.y.coerceIn(d.y, d.bottom - win.h)
    }

    fun open(app: App, maximized: Boolean = false): Window {
        val win = Window(app)
        win.maximized = maximized
        windows.add(win)
        if (landscape && !maximized) placeNew(win, windows.size - 1) else clampWindow(win)
        clampWindow(win)
        focus(win)
        saveRequested = true
        return win
    }

    /** Set when the window list changed; the session is saved on the next tick. */
    private var saveRequested = false

    fun focus(win: Window?) {
        if (win != null && win !in windows) return
        if (win !== focused) {
            releaseInputOwnership()
            dialog?.let { old -> old.cancel(); if (dialog === old) closeDialog() }
        }
        if (win != null && windows.remove(win)) windows.add(win)
        focused = win
        menu = null
        keyboardOverride = 0
        // modifiers and keyboard layers never carry over to another window
        ctrlLatched = false; altLatched = false; keyboard.reset()
        syncKeyboard()
        relayout(false)
        invalidate()
    }

    fun close(win: Window, force: Boolean = false) {
        if (!force && win.app.unsaved) {
            showDialog(Dialog.confirmDestructive( { tr("dialog.close_unsaved.title", "title" to win.app.title) }, { tr("dialog.close_unsaved.message") }, { tr("button.close") }) { close(win, true) })
            invalidate(); return
        }
        if (win === focused) releaseInputOwnership()
        win.app.close()
        windows.remove(win)
        if (focused === win) focus(windows.firstOrNull { it.id == win.app.navigationParentId } ?: windows.lastOrNull())
        saveSession()
        invalidate()
    }

    fun findWindow(kind: String, pred: (App) -> Boolean = { true }) = windows.firstOrNull { it.app.kind == kind && pred(it.app) }

    fun showToast(msg: String) = showToast { msg }
    fun showToast(msg: () -> String) { toast = L10n.Presentation(msg); toastUntil = env.nowMs() + 2500; invalidate() }

    fun showDialog(d: Dialog) {
        releaseInputOwnership()
        dialog?.cancel()
        dialog = d
        syncKeyboard()
        invalidate()
    }

    private fun closeDialog() {
        releaseInputOwnership()
        dialog = null
        syncKeyboard()
    }

    val dialogOpen get() = dialog != null
    /** A menu or dialog is open (program frames are then drawn into the surface instead of as overlays). */
    val popupOpen get() = dialog != null || menu != null

    /**
     * True when [app]'s program picture must be drawn into the surface instead of as an
     * overlay: overlays are composited above the whole surface, so they would show through
     * a popup or (landscape) a window stacked above that covers part of the client area.
     */
    fun drawsFrameInSurface(app: App): Boolean {
        if (popupOpen) return true
        if (!landscape) return false
        val i = windows.indexOfFirst { it.app === app }
        if (i < 0) return false
        val c = clientRect(windows[i])
        for (j in i + 1 until windows.size) {
            val o = windows[j]
            if (o.x < c.right && c.x < o.x + o.w && o.y < c.bottom && c.y < o.y + o.h) return true
        }
        return false
    }

    /** Opens a menu at ([x], [y]); opened by another menu's item, it is that menu's submenu (back returns). */
    fun showMenu(items: List<MenuItem>, x: Int, y: Int, title: String? = null) {
        showMenu(items, x, y, { title })
    }
    fun showMenu(items: List<MenuItem>, x: Int, y: Int, title: () -> String?) {
        releaseInputOwnership()
        menu = PopupMenu(items, x, y, title, menuSource)
        invalidate()
    }

    // ------------------------------------------------------------ frame loop

    /** Called by the platform each display frame. Returns true if the surface changed. */
    fun tick(): Boolean {
        val now = env.nowMs()
        syncCompact()
        if (templeKeyboardShown && keyboard.tick(now)) invalidate()
        if (heldHw.isNotEmpty()) repeatHardwareKeys(now)
        while (true) { val f = uiQueue.poll() ?: break; f() }
        for (w in windows.toList()) if (w.app.tick(now)) w.app.dirty = true
        for (w in windows.toList()) {
            val vis = landscape || w === focused
            if (w.shownState != vis) { w.shownState = vis; w.app.onVisibility(vis) }
        }
        if (toast != null && now > toastUntil) { toast = null; needsRender = true }
        if (windows.any { it.app.dirty }) needsRender = true
        syncKeyboard()
        if (saveRequested) { saveRequested = false; saveSession() }
        if (!needsRender) return false
        render()
        return true
    }

    /** Current program frames to draw over the surface (device-resolution scaling). */
    fun overlays(): List<Overlay> {
        if (dialog != null || menu != null) {
            // keep frames visible under the dialog except where covered
        }
        val res = ArrayList<Overlay>()
        val visible = if (landscape) windows else listOfNotNull(focused)
        for (w in visible) {
            if (drawsFrameInSurface(w.app)) continue // drawn into the surface at its z-position
            val client = clientRect(w)
            for (o in w.app.overlays(client)) res.add(o)
        }
        // overlays are drawn on top of the surface, so hide them when a popup covers them
        if (dialog != null || menu != null) return res.filter { o -> !coveredByPopup(o.rect) }
        return res
    }

    private fun coveredByPopup(r: Rect): Boolean = true

    // ------------------------------------------------------------ rendering

    fun clientRect(w: Window): Rect {
        if (borderless(w)) return desktopRect()
        // client area inside the TempleOS border: 8px border on each side
        return Rect(w.x + 8, w.y + 8 + chromeH, maxOf(0, w.w - 16), maxOf(0, w.h - 16 - chromeH))
    }

    private fun render() {
        syncCompact()
        a11yBase.clear(); a11yKeys.clear(); a11yModal.clear(); a11yTarget = a11yBase
        a11yVersion++
        val s = surface
        s.setClip(null)
        s.beginFrame()
        s.fillRect(0, 0, width, height, settings.desktopColor)
        val d = desktopRect()
        if (windows.isEmpty()) drawEmptyDesktop(s, d)
        if (landscape && !typingCompact) {
            for (w in windows) drawWindow(s, w)
        } else {
            focused?.let { drawWindow(s, it) }
        }
        if (!typingCompact) { s.layer(Rect(0, 0, width, insetTop + barH)); drawTopBar(s) }
        a11yTarget = a11yKeys
        if (templeKeyboardShown) {
            val r = keyboardRect()
            s.layer(Rect(0, r.y, width, height - r.y))
            s.fillRect(0, r.y, width, height - r.y, BAR_BG)
            keyboard.draw(s, r)
        } else if (focusedWantsKeyRow()) { s.layer(keyRowRect()); drawKeyRow(s) }
        a11yTarget = a11yModal
        menu?.draw(s, this)
        dialog?.draw(s, this)
        a11yTarget = a11yBase
        systemChrome = resolveSystemChrome()
        drawSystemGutters(s, systemChrome)
        toast?.let { drawToast(s, it.value) }
        needsRender = false
        windows.forEach { it.app.dirty = false }
        s.touch()
    }

    // ------------------------------------------------------------ system chrome

    /**
     * What the system navigation region, home indicator and side gutters show, resolved by the last
     * render from what it drew ([SystemChrome]). The platform adapters read it after each frame.
     */
    var systemChrome = SystemChrome(Palette.DKGRAY, Palette.DKGRAY, SystemChrome.Owner.DESKTOP)
        private set

    /** The windows, bottom bars and popups that can own the bottom edge, as the last render drew them. */
    private fun resolveSystemChrome(): SystemChrome {
        val shown = if (landscape && !typingCompact) windows else listOfNotNull(focused)
        val content = shown.map { w ->
            val app = w.app.systemEdgeColor
            val r = if (borderless(w)) clientRect(w) else Rect(w.x, w.y, w.w, w.h)
            SystemChrome.Layer(r, app ?: WINDOW_BG, if (app != null) SystemChrome.Owner.APP_OVERRIDE else SystemChrome.Owner.WINDOW)
        }
        val bars = ArrayList<SystemChrome.Layer>(3)
        if (templeKeyboardShown) bars.add(SystemChrome.Layer(keyboardRect(), BAR_BG, SystemChrome.Owner.KEYBOARD))
        else if (focusedWantsKeyRow()) bars.add(SystemChrome.Layer(keyRowRect(), BAR_BG, SystemChrome.Owner.KEY_ROW))
        menu?.let { bars.add(SystemChrome.Layer(it.bounds, PopupMenu.BG, SystemChrome.Owner.POPUP)) }
        dialog?.let { bars.add(SystemChrome.Layer(it.bounds, Dialog.BG, SystemChrome.Owner.POPUP)) }
        val d = desktopRect()
        return SystemChrome.resolve(
            settings.desktopColor, content, d.bottom, bars, height - insetBottom,
            insetLeft, width - insetRight,
            deviceKeyboard = false,
            defersEdgeGestures = focused?.app?.defersEdgeGestures == true,
        )
    }

    /**
     * Paints the regions the system draws over (navigation bar / home indicator below, side gutters
     * in landscape) in the colors of the surface that owns the edge, so a transparent system bar
     * continues the TempleOS screen instead of showing a strip of another color. Beside a bottom bar
     * (TempleOS keyboard, key row) the side gutters take its color. The top bar already covers the
     * status bar. Each gutter is a layer: localized text never shows through.
     */
    private fun drawSystemGutters(s: Surface, c: SystemChrome) {
        val top = insetTop + topBarH
        val usableBottom = height - insetBottom
        val barTop = maxOf(top, usableBottom - bottomBarHeight())
        fun gutter(x: Int, y: Int, w: Int, h: Int, color: Int) {
            if (w <= 0 || h <= 0) return
            s.layer(Rect(x, y, w, h)); s.fillRect(x, y, w, h, color)
        }
        gutter(0, top, insetLeft, barTop - top, c.side)
        gutter(width - insetRight, top, insetRight, barTop - top, c.side)
        gutter(0, barTop, insetLeft, usableBottom - barTop, c.bottom)
        gutter(width - insetRight, barTop, insetRight, usableBottom - barTop, c.bottom)
        gutter(0, usableBottom, width, height - usableBottom, c.bottom)
    }

    private fun drawEmptyDesktop(s: Surface, d: Rect) {
        val lines = Brand.INTRO_LINES
        var y = d.y + d.h / 3
        for ((i, l) in lines.withIndex()) {
            val startY = y
            for (part in s.wrapUi(l, d.w - 16)) {
                s.uiText(d.x + (d.w - s.measureUi(part)) / 2, y, part, if (i == 0) Palette.YELLOW else Palette.LTGRAY)
                y += 16
            }
            a11yText(Rect(d.x, startY, d.w, y - startY), l)
        }
    }

    private fun drawTopBar(s: Surface) {
        val y = insetTop
        val m = metrics; val ts = m.textScale; val bh = m.barH
        val ty = y + (bh - m.glyphH) / 2
        s.fillRect(0, 0, width, y + bh, Palette.BLACK)
        // MENU chip (TempleOS draws a blinking MENU button top-left)
        val menuLabel = if (windows.isEmpty()) "MENU" else tr("topbar.menu")
        val usable = width - insetLeft - insetRight
        val chipW = minOf(usable / 3, maxOf(6 * m.charW, s.measureUi(menuLabel, ts) + 2 * m.padX))
        menuChipW = chipW
        s.fillRect(insetLeft, y, chipW, bh, Palette.BLUE)
        s.uiText(insetLeft + m.padX, ty, menuLabel, Palette.YELLOW, chipW - 2 * m.padX, scale = ts)
        a11yButton(Rect(insetLeft, y, chipW + 4, bh), menuLabel)
        // window deck / task list: the focused window's tab always shows (shortened if it must), then the
        // others while they fit, then a "+N" chip listing the rest
        var x = insetLeft + chipW + m.charW / 2
        val cal = java.util.Calendar.getInstance()
        val clock = "%02d:%02d".format(java.util.Locale.ROOT, cal.get(java.util.Calendar.HOUR_OF_DAY), cal.get(java.util.Calendar.MINUTE))
        tabRects.clear()
        overflowChip = null
        val ordered = listOfNotNull(focused) + windows.filter { it !== focused }
        val overW = 3 * m.charW + m.padX / 2
        // on a narrow screen the clock gives way to the focused window's tab (at least 5 characters)
        val withClock = width - insetRight - (clock.length * m.charW + m.padX)
        val showClock = ordered.isEmpty() || withClock - x - (if (ordered.size > 1) overW + 4 else 0) >= 5 * m.charW + m.padX
        val limit = if (showClock) withClock else width - insetRight - 4
        for ((i, w) in ordered.withIndex()) {
            val t = w.app.title
            var tw = minOf(s.measureUi(t, ts), (if (landscape) 14 else 10) * m.charW) + m.padX
            val needChip = i < ordered.size - 1
            val room = limit - x - (if (needChip) overW + 4 else 0)
            if (tw > room) {
                if (i == 0 && room >= 3 * m.charW) tw = room
                else {
                    val chip = Rect(x, y + 2, minOf(overW, maxOf(m.charW * 2, limit - x)), bh - 4)
                    s.fill(chip, Palette.BROWN)
                    s.text(chip.x + m.padX / 4, ty, "+${ordered.size - i}".take(3), Palette.YELLOW, scale = ts)
                    overflowChip = chip
                    a11yButton(Rect(chip.x, y, chip.w, bh), tr("a11y.more_windows", "count" to ordered.size - i))
                    break
                }
            }
            val active = w === focused
            s.fillRect(x, y + 2, tw, bh - 4, if (active) Palette.WHITE else Palette.DKGRAY)
            s.uiText(x + m.padX / 2, ty, t, if (active) Palette.BLUE else Palette.WHITE, tw - m.padX, scale = ts)
            tabRects.add(Rect(x, y, tw, bh) to w)
            a11yButton(Rect(x, y, tw, bh), tr("a11y.window", "title" to w.app.title), active)
            x += tw + 4
        }
        if (showClock) {
            val cx = width - insetRight - clock.length * m.charW - m.padX / 2
            s.text(cx, ty, clock, Palette.LTGREEN, scale = ts)
            a11yText(Rect(cx, y, clock.length * m.charW, bh), tr("a11y.time", "time" to clock))
        }
    }

    private val tabRects = ArrayList<Pair<Rect, Window>>()
    private var menuChipW = 48
    private var overflowChip: Rect? = null

    /** Lists every open window (used when the top bar cannot show them all). */
    fun showWindowList() {
        showMenu(windows.map { w -> MenuItem( { w.app.title }, checked = w === focused) { focus(w) } }, overflowChip?.x ?: (width / 3), insetTop + barH, { tr("menu.windows.title") })
    }

    private fun drawWindow(s: Surface, w: Window) {
        // each window is a stacking layer: it hides the native text of the windows below
        s.layer(if (borderless(w)) clientRect(w) else Rect(w.x, w.y, w.w, w.h))
        if (borderless(w)) {
            val client = clientRect(w)
            s.fillRect(client.x, client.y, client.w, client.h, WINDOW_BG)
            w.app.a11yItems.clear()
            s.withClip(client) { w.app.draw(s, client) }
            w.app.accessibility(client)
            return
        }
        val r = Rect(w.x, w.y, w.w, w.h)
        val active = w === focused
        val bg = WINDOW_BG
        s.fillRect(r.x, r.y, r.w, r.h, bg)
        s.border(Rect(r.x, r.y, r.w and 7.inv(), r.h and 7.inv()), if (active) Palette.BLUE else Palette.LTBLUE, bg, active, " ${w.app.title} ")
        // chrome row: [≡] menu   ...   [-] max [X]  (MenuMetrics: text at the menu scale, touch-sized row)
        val m = metrics; val ts = m.textScale
        val ch = m.chromeH; val cb = m.chromeBtnW
        val cy = r.y + 8
        val gy = cy + (ch - m.glyphH) / 2
        s.fillRect(r.x + 8, cy, r.w - 16, ch, if (active) Palette.BLUE else Palette.LTBLUE)
        val mw = menuBtnW(w)
        s.text(r.x + 8 + m.charW / 2, gy, "\u00F0", Palette.WHITE, scale = ts) // menu glyph
        s.uiText(r.x + 8 + 2 * m.charW, gy, tr("window.menu"), Palette.YELLOW, maxOf(0, mw - 8 - 2 * m.charW), scale = ts)
        val bx = r.right - 8 - 3 * cb
        if (landscape) s.text(bx + (cb - m.charW) / 2, gy, if (w.maximized) "\u00FE" else "\u001E", Palette.WHITE, scale = ts)
        s.text(bx + 2 * cb + (cb - m.charW) / 2, gy, "X", Palette.LTRED, scale = ts)
        if (active) {
            a11yButton(Rect(r.x + 8, cy, mw - 8, ch), tr("a11y.window_menu", "title" to w.app.title))
            if (landscape) a11yButton(Rect(bx, cy, cb, ch), tr(if (w.maximized) "a11y.restore_window" else "a11y.maximize_window"))
            a11yButton(Rect(bx + 2 * cb, cy, cb, ch), tr("a11y.close_window", "title" to w.app.title))
        }
        val client = clientRect(w)
        w.app.a11yItems.clear()
        s.withClip(client) { w.app.draw(s, client) }
        if (active) w.app.accessibility(client)
    }

    /**
     * The key row under text apps while no on-screen TempleOS keyboard is shown. The last key
     * shows the keyboard again; with the device keyboard, TOS switches back to the TempleOS one.
     * At most 10 keys, so 4-letter labels fit a 360 px screen (HOME/END: the keyboard's FN layer).
     */
    private val keyRow get() = listOf("ESC", "TAB", "CTRL", "ALT", "\u001B", "\u0018", "\u0019", "\u001A", "\u00FB")

    private fun keyRowA11y(k: String) = when (k) {
        "ESC" -> tr("key.escape"); "TAB" -> tr("key.tab"); "CTRL" -> tr("key.control"); "ALT" -> tr("key.alt"); "\u001B" -> tr("key.left")
        "\u0018" -> tr("key.up"); "\u0019" -> tr("key.down"); "\u001A" -> tr("key.right"); "HOME" -> tr("key.home"); "END" -> tr("key.end")
        "TOS" -> tr("key.use_templeos_keyboard"); "\u00FB" -> tr("key.show_hide_keyboard"); else -> k
    }

    private fun keyRowRect(): Rect {
        val bottom = height - insetBottom
        return Rect(insetLeft, bottom - KEY_ROW, width - insetLeft - insetRight, KEY_ROW)
    }

    /** Where the TempleOS keyboard is drawn: above the home indicator / navigation bar. */
    fun keyboardRect(): Rect {
        val h = keyboard.height()
        val bottom = height - insetBottom
        return Rect(insetLeft, bottom - h, width - insetLeft - insetRight, h)
    }

    var ctrlLatched = false; private set
    var altLatched = false; private set
    fun toggleCtrl() { setLatches(!ctrlLatched, altLatched) }
    fun toggleAlt() { setLatches(ctrlLatched, !altLatched) }

    /** Sets the CTRL/ALT latches, telling a running program the key went down or up. */
    private fun setLatches(ctrl: Boolean, alt: Boolean) {
        if (ctrl != ctrlLatched) { ctrlLatched = ctrl; latchEvent(Keys.SC_CTRL, ctrl) }
        if (alt != altLatched) { altLatched = alt; latchEvent(Keys.SC_ALT, alt) }
        invalidate()
    }

    /** The on-screen SHIFT latch (TempleKeyboard): a running program sees SHIFT down while it is on. */
    fun shiftLatch(on: Boolean) = latchEvent(Keys.SC_SHIFT, on)

    /** Pointer ids pressing TempleOS keyboard keys (several fingers can type at once). */
    private val keyboardPointers = HashSet<Int>()

    private fun drawKeyRow(s: Surface) {
        val r = keyRowRect()
        s.fillRect(r.x, r.y, r.w, r.h, BAR_BG)
        val keys = keyRow
        for ((i, k) in keys.withIndex()) {
            val x0 = r.x + i * r.w / keys.size; val x1 = r.x + (i + 1) * r.w / keys.size
            val on = (k == "CTRL" && ctrlLatched) || (k == "ALT" && altLatched)
            val kr = Rect(x0, r.y, x1 - x0, r.h)
            s.templeButton(kr, k, if (on) ButtonFace.SELECTED else ButtonFace.NORMAL)
            a11yButton(kr, keyRowA11y(k), on)
        }
    }

    private fun drawToast(s: Surface, msg: String) {
        val m = metrics; val ts = m.textScale
        // localized: the TempleOS font when it has every character, else the platform's (Surface.uiText); it was
        // drawn byte by byte in the TempleOS font, which garbled every non-ASCII message
        val w = minOf(width - insetLeft - insetRight - 16, s.measureUi(msg, ts) + 2 * m.padX)
        val area = desktopRect()
        val lines = s.wrapUi(msg, maxOf(8, w - 2 * m.padX), ts)
        val th = minOf(maxOf(16, area.h - 16), lines.size * m.lineH + 12)
        val x = insetLeft + (width - insetLeft - insetRight - w) / 2
        val y = maxOf(area.y + 4, area.bottom - th - 12)
        s.layer(Rect(x, y, w, th))
        s.fillRect(x, y, w, th, Palette.BLACK)
        s.frame(Rect(x, y, w, th), Palette.YELLOW)
        a11yText(Rect(x, y, w, th), msg)
        s.withClip(Rect(x + 1, y + 1, w - 2, th - 2)) {
            for ((i, line) in lines.withIndex())
                s.uiText(x + m.padX, y + 6 + i * m.lineH, line, Palette.YELLOW,
                    maxW = maxOf(0, w - 2 * m.padX), alignEnd = L10n.rtl, scale = ts)
        }
    }

    // ------------------------------------------------------------ input

    private var downX = 0; private var downY = 0; private var downTime = 0L
    private var lastX = 0; private var lastY = 0
    private var gesture = 0 // 0 none, 1 pending tap, 2 dragging/scrolling, 3 window move, 4 window resize, 5 raw app, 6 long-pressed
    private var gestureWin: Window? = null
    private var primaryId = 0
    private val extraPointers = HashSet<Int>()
    private var popupPointerOwner: Any? = null
    private var popupPointerId: Int? = null

    // A key/program may open a popup during DOWN. Its UP still belongs to the
    // previous context, so only a pointer begun in this popup may choose a row.
    private fun ownsPopupPointer(e: PointerEvent, owner: Any): Boolean {
        if (e.action == Ptr.DOWN) {
            if (popupPointerId != null && popupPointerOwner === owner) return false
            popupPointerOwner = owner; popupPointerId = e.id
            return true
        }
        if (popupPointerOwner !== owner || popupPointerId != e.id) return false
        if (e.action == Ptr.UP || e.action == Ptr.CANCEL) { popupPointerOwner = null; popupPointerId = null }
        return true
    }

    fun pointer(e: PointerEvent) {
        val now = if (e.timeMs != 0L) e.timeMs else env.nowMs()
        syncCompact()
        // the TempleOS keyboard takes its touches first (also while a dialog asks for text)
        if (templeKeyboardShown && (e.id in keyboardPointers || (e.action == Ptr.DOWN && menu == null && keyboardRect().contains(e.x, e.y)))) {
            if (e.action == Ptr.DOWN) keyboardPointers.add(e.id)
            if (e.action == Ptr.UP || e.action == Ptr.CANCEL) keyboardPointers.remove(e.id)
            keyboard.pointer(e, env.nowMs())
            return
        }
        if (dialog != null || menu != null) endGestureUnderPopup(e)
        dialog?.let { d ->
            if (!ownsPopupPointer(e, d)) return
            if (d.pointer(e, this) && dialog === d) closeDialog()
            invalidate(); return
        }
        menu?.let { m -> if (ownsPopupPointer(e, m)) menuPointer(m, e); return }
        // Extra fingers while a gesture is active go straight to the focused app
        // (e.g. holding two on-screen game buttons at once).
        if (e.id in extraPointers || (gesture != 0 && e.id != primaryId && e.action == Ptr.DOWN)) {
            val w = focused
            if (e.action == Ptr.DOWN) extraPointers.add(e.id)
            if (e.action == Ptr.UP || e.action == Ptr.CANCEL) extraPointers.remove(e.id)
            if (w != null) w.app.pointer(e, clientRect(w))
            return
        }
        if (e.id != primaryId && e.action != Ptr.DOWN) return
        when (e.action) {
            Ptr.DOWN -> {
                primaryId = e.id
                downX = e.x; downY = e.y; lastX = e.x; lastY = e.y; downTime = now
                gesture = 1; gestureWin = null
                if (e.y < insetTop + topBarH) return
                if (focusedWantsKeyRow() && keyRowRect().contains(e.x, e.y)) return
                val win = windowAt(e.x, e.y)
                gestureWin = win
                if (win != null && win !== focused) focus(win)
                if (win != null) {
                    val client = clientRect(win)
                    if (landscape && !win.maximized && !borderless(win) && e.y < win.y + 8 + chromeH && e.x < win.right() - 8 - 3 * chromeBtnW && e.x > win.x + menuBtnW(win)) { gesture = 3; return }
                    if (landscape && !win.maximized && !borderless(win) && e.x > win.right() - 12 && e.y > win.bottom() - 12) { gesture = 4; return }
                    if (client.contains(e.x, e.y) && win.app.pointer(e, client)) { gesture = 5; return }
                }
            }
            Ptr.MOVE -> {
                val win = gestureWin
                when (gesture) {
                    5 -> win?.let { it.app.pointer(e, clientRect(it)) }
                    3 -> win?.let { it.x += e.x - lastX; it.y += e.y - lastY; clampWindow(it); invalidate() }
                    4 -> win?.let { it.w += e.x - lastX; it.h += e.y - lastY; clampWindow(it); it.app.dirty = true; invalidate() }
                    1, 2 -> {
                        if (gesture == 1 && (Math.abs(e.x - downX) > 6 || Math.abs(e.y - downY) > 6)) gesture = 2
                        if (gesture == 2 && win != null) win.app.scroll(e.x - lastX, e.y - lastY, clientRect(win))
                    }
                }
                lastX = e.x; lastY = e.y
            }
            Ptr.UP, Ptr.CANCEL -> {
                val win = gestureWin
                if (gesture == 5) win?.let { it.app.pointer(e, clientRect(it)) }
                else if (gesture == 1 && e.action == Ptr.UP) {
                    if (now - downTime > LONG_PRESS_MS && win != null && clientRect(win).contains(e.x, e.y))
                        win.app.longPress(e.x, e.y, clientRect(win))
                    else click(e.x, e.y, win)
                }
                if (gesture == 3 || gesture == 4) saveSession()
                gesture = 0; gestureWin = null
            }
        }
    }

    private var menuDownY = 0
    private var menuDragged = false
    /** The menu whose item is running (a menu opened by that item is its submenu). */
    private var menuSource: PopupMenu? = null

    /**
     * Touch on an open menu: a tap runs an item, scrolls (arrow rows) or goes back (a submenu's title row);
     * a vertical drag scrolls by rows and runs nothing; a tap outside closes the menu and goes nowhere else
     * (dismissing a menu never reaches the program or window under it).
     */
    private fun menuPointer(m: PopupMenu, e: PointerEvent) {
        when (e.action) {
            Ptr.DOWN -> { menuDownY = e.y; menuDragged = false }
            Ptr.MOVE -> {
                val dy = e.y - menuDownY
                if (Math.abs(dy) >= m.rowStep) { if (m.scrollBy(-dy / m.rowStep)) invalidate(); menuDownY = e.y; menuDragged = true }
            }
            Ptr.UP -> {
                if (menuDragged) { menuDragged = false; return }
                when (val h = m.hit(e.x, e.y)) {
                    PopupMenu.HIT_OUTSIDE -> menu = null
                    PopupMenu.HIT_UP -> m.scrollBy(-m.page)
                    PopupMenu.HIT_DOWN -> m.scrollBy(m.page)
                    PopupMenu.HIT_BACK -> menu = m.parent
                    PopupMenu.HIT_NONE -> {}
                    else -> runMenuItem(m, h)
                }
                invalidate()
            }
            Ptr.CANCEL -> menuDragged = false
        }
    }

    /** Closes [m] and runs its item [i]; a menu the item opens becomes [m]'s submenu. */
    private fun runMenuItem(m: PopupMenu, i: Int) {
        val item = m.items.getOrNull(i)?.takeIf { it.enabled } ?: return
        menu = null
        menuSource = m
        try { item.action() } finally { menuSource = null }
    }

    /** The open menu, for tests and accessibility (null when none). */
    val openMenu: PopupMenu? get() = menu

    /**
     * A popup opened during a gesture consumes the rest of it: the gesture still
     * has to end here (touch ids differ per touch on iOS, so a gesture left open
     * would turn every later touch into an "extra finger"), and an app holding
     * the pointer gets CANCEL so held controls are released.
     */
    private fun endGestureUnderPopup(e: PointerEvent) {
        if (e.action != Ptr.UP && e.action != Ptr.CANCEL) return
        val cancel = PointerEvent(Ptr.CANCEL, e.x, e.y, e.id, e.timeMs)
        if (extraPointers.remove(e.id)) focused?.let { it.app.pointer(cancel, clientRect(it)) }
        if (e.id == primaryId && gesture != 0) {
            if (gesture == 5) gestureWin?.let { it.app.pointer(cancel, clientRect(it)) }
            gesture = 0; gestureWin = null
        }
    }

    private fun Window.right() = x + w
    private fun Window.bottom() = y + h

    private fun windowAt(x: Int, y: Int): Window? {
        if (typingCompact) return focused?.takeIf { desktopRect().contains(x, y) }
        if (!landscape) return focused?.takeIf { Rect(it.x, it.y, it.w, it.h).contains(x, y) }
        return windows.lastOrNull { Rect(it.x, it.y, it.w, it.h).contains(x, y) }
    }

    private fun click(x: Int, y: Int, win: Window?) {
        if (y < insetTop + topBarH) {
            if (x < insetLeft + menuChipW + 4) { showStartMenu(); return }
            tabRects.firstOrNull { it.first.contains(x, y) }?.let { focus(it.second); return }
            overflowChip?.let { c -> if (x >= c.x && x < c.right) showWindowList() }
            return
        }
        if (focusedWantsKeyRow() && keyRowRect().contains(x, y)) { keyRowTap(x); return }
        if (win == null) return
        val cy = win.y + 8
        if (!borderless(win) && y in cy until cy + chromeH + 8 && y >= win.y) {
            val bx = win.right() - 8 - 3 * chromeBtnW
            when {
                x < win.x + menuBtnW(win) -> showWindowMenu(win, win.x + 8, cy + chromeH)
                x >= bx + 2 * chromeBtnW -> close(win)
                x >= bx && landscape -> { win.maximized = !win.maximized; relayout(false); clampWindow(win); win.app.dirty = true; invalidate() }
            }
            return
        }
        val client = clientRect(win)
        if (client.contains(x, y)) win.app.tap(x, y, client)
    }

    private fun keyRowTap(x: Int) {
        val r = keyRowRect()
        val keys = keyRow
        val i = ((x - r.x) * keys.size / maxOf(1, r.w)).coerceIn(0, keys.size - 1)
        when (keys[i]) {
            "CTRL" -> { toggleCtrl(); return }
            "ALT" -> { toggleAlt(); return }
            "TOS" -> { setKeyboardMode(Settings.KEYBOARD_TEMPLEOS); return }
            "\u00FB" -> { keyboardOverride = if (templeKeyboardShown) -1 else 1; syncKeyboard(); return }
        }
        val (ch, sc) = when (keys[i]) {
            "ESC" -> Keys.special(Keys.SC_ESC)
            "TAB" -> Keys.special(Keys.SC_TAB)
            "\u001B" -> Keys.special(Keys.SC_CURSOR_LEFT)
            "\u001A" -> Keys.special(Keys.SC_CURSOR_RIGHT)
            "\u0018" -> Keys.special(Keys.SC_CURSOR_UP)
            "\u0019" -> Keys.special(Keys.SC_CURSOR_DOWN)
            "HOME" -> Keys.special(Keys.SC_HOME)
            "END" -> Keys.special(Keys.SC_END)
            else -> return
        }
        key(ch, sc, true); key(ch, sc or Keys.SCF_KEY_UP, false)
    }

    /** Key input from hardware keyboards, the key row or the soft keyboard. */
    fun key(ch0: Int, sc0: Long, down: Boolean) {
        if (!inputActive || ch0 !in 0..255) return
        val (ch, sc) = resolvedKey(ch0, sc0)
        // a latch applies to one key: it is lifted after that key's own release
        if (!down && (ctrlLatched || altLatched)) { routeKey(ch, sc, down); setLatches(false, false); return }
        routeKey(ch, sc, down)
    }

    fun resolvedKey(ch0: Int, sc0: Long): Pair<Int, Long> {
        var ch = ch0; var sc = sc0
        if (ctrlLatched) { sc = sc or Keys.SCF_CTRL; if (ch in 97..122 || ch in 65..90) ch = ch and 0x1F }
        if (altLatched) sc = sc or Keys.SCF_ALT
        return ch to sc
    }

    private fun routeKey(ch: Int, sc: Long, down: Boolean) {
        dialog?.let { d -> if (down && d.key(ch, sc, this) && dialog === d) closeDialog(); invalidate(); return }
        if (down && sc and Keys.SCF_CTRL != 0L && sc and 127 == 0x32L) {showStartMenu();return}
        menu?.let { m ->
            // an open menu takes every key (none reaches the program under it); releases are dropped
            if (!down) return
            if (ch == Keys.CH_ESC || ch == Keys.CH_SHIFT_ESC) { menu = null; invalidate(); return }
            when (val r = m.key(ch, sc)) {
                PopupMenu.KEY_BACK -> menu = m.parent ?: m
                -1 -> {}
                else -> runMenuItem(m, r)
            }
            invalidate(); return
        }
        focused?.app?.key(ch, sc, down)
    }

    /** Internal byte text. External Unicode must use insertUnicodeText. */
    fun text(s: String) {
        if (!inputActive || !InputCharacterPolicy.isByteText(s)) { rejectInput(); return }
        if (dialog != null || menu != null || ctrlLatched || altLatched) {
            for (c in s) { val (ch, sc) = Keys.forChar(c.code); key(ch, sc, true); key(ch, sc or Keys.SCF_KEY_UP, false) }
        } else focused?.app?.text(s)
    }

    fun insertUnicodeText(s: String, lease: InputLease? = null): Boolean {
        if (!inputActive || (lease != null && lease != inputLease)) return false
        val bytes = InputCharacterPolicy.encode(s, dialog?.wantsKeyboard == true) ?: run { rejectInput(); return false }
        // Paste is data, even when invoked synchronously by a sticky Ctrl-V key-down.
        setLatches(false, false)
        text(bytes); return true
    }
    fun pasteClipboard() { env.clipboardGet()?.let { insertUnicodeText(it) } }
    var rejectedInputCount = 0
        private set
    fun rejectInput() { rejectedInputCount++; showToast( { tr("input.unsupported") }) }

    data class InputLease(val generation: Int, val target: String)
    var inputGeneration = 0
        private set
    private var inputActive = true
    val inputTarget get() = when {
        !inputActive -> "inactive"
        dialog != null -> "dialog"
        menu != null -> "menu"
        else -> focused?.let { "${it.app.kind}:${it.id}" } ?: "none"
    }
    val inputLease get() = InputLease(inputGeneration, inputTarget)
    fun releaseInputOwnership() {
        releaseHardwareKeys(); keyboard.reset(); setLatches(false, false)
        focused?.app?.releaseInput()
        gesture = 0; gestureWin = null; extraPointers.clear()
        keyboardPointers.clear(); popupPointerOwner = null; popupPointerId = null; inputGeneration++
    }

    fun showCharacterPicker() {
        val lease = inputLease; val owner = focused; val parent = dialog
        val options = (128..255).map { "%02X  ".format(java.util.Locale.ROOT, it) + Cp437.decode(it.toChar().toString()) to it.toLong() }
        val picker = Dialog.choose( { "CP437" }, { "" }, { options }, emptyList()) { value ->
            post {
                if (focused !== owner || dialog != null || inputGeneration != lease.generation + 2) { parent?.cancel(); return@post }
                dialog = parent; syncKeyboard()
                if (value in 128..255) text(value.toInt().toChar().toString())
                invalidate()
            }
        }
        releaseInputOwnership(); dialog = picker; syncKeyboard(); invalidate()
    }

    /** Android/iOS "back" gesture: close menus/dialogs, else unfocus. Returns false if nothing to do. */
    fun back(): Boolean {
        dialog?.let { d -> d.cancel(); if (dialog === d) closeDialog(); invalidate(); return true }
        menu?.let { m -> menu = m.parent; invalidate(); return true } // a submenu goes back, a menu closes
        if (templeKeyboardShown) { hideKeyboard(); return true }
        if (focused?.app?.navigateBack() == true) return true
        return false
    }

    // ------------------------------------------------------------ menus

    fun showStartMenu() {
        val items = ArrayList<MenuItem>()
        items.add(MenuItem( { tr("menu.start.terminal") }) { Launch.terminal(this) })
        items.add(MenuItem( { tr("menu.start.editor") }) { Launch.editor(this, null) })
        items.add(MenuItem( { tr("menu.start.files") }) { Launch.files(this, "C:/Home") })
        items.add(MenuItem( { tr("menu.start.games") }) { Launch.games(this) })
        for(id in listOf("applications","programs","demos")) catalog.group(id)?.let {g->items.add(MenuItem( { if(id=="demos")tr("menu.start.demos") else g.localizedTitle }) {Launch.programs(this,id)})}
        items.add(MenuItem( { tr("menu.start.examples") }) { showMenu(catalog.menuItems(this, "example"), insetLeft + 4, insetTop + barH, { tr("menu.examples.title") }) })
        items.add(MenuItem( { tr("menu.start.documentation") }) { Launch.doc(this, "C:/Doc/HelpIndex.DD") })
        items.add(MenuItem( { tr("menu.start.god_words") }) { Launch.god(this) })
        items.add(MenuItem( { tr("menu.start.paint") }) { Launch.paint(this) })
        items.add(MenuItem( { tr("menu.start.settings") }) { Launch.settings(this) })
        items.add(MenuItem( { tr("menu.start.language") }) { Launch.language(this) })
        items.add(MenuItem( { tr("menu.start.about") }) { Launch.about(this) })
        showMenu(items, insetLeft + 4, insetTop + barH, { "TempleOS" })
    }

    private fun showWindowMenu(win: Window, x: Int, y: Int) {
        val items = ArrayList(win.app.menu())
        if (landscape) items.add(MenuItem( { tr(if (win.maximized) "menu.window.restore" else "menu.window.maximize") }) {
            win.maximized = !win.maximized; relayout(false); clampWindow(win); win.app.dirty = true; invalidate()
        })
        if (landscape) items.add(MenuItem( { tr("menu.window.tile") }) { tile() })
        items.add(MenuItem( { tr("menu.window.close") }) { close(win) })
        showMenu(items, x, y, { win.app.title })
    }

    fun tile() {
        val d = desktopRect()
        val n = windows.size
        if (n == 0) return
        val cols = if (n <= 2) n else 2
        val rows = (n + cols - 1) / cols
        for ((i, w) in windows.withIndex()) {
            w.maximized = false
            w.w = (d.w / cols) and 7.inv(); w.h = (d.h / rows) and 7.inv()
            w.x = d.x + (i % cols) * w.w; w.y = d.y + (i / cols) * w.h
            w.app.dirty = true
        }
        invalidate()
    }

    // ------------------------------------------------------------ session

    fun saveSession() {
        val sb = StringBuilder()
        sb.append("v1\n")
        sb.append("settings\t").append(settings.encode()).append('\n')
        for (w in windows) {
            val st = w.app.saveState().toMutableMap()
            st["_windowId"]=w.id.toString();w.app.navigationParentId?.let {st["_parentId"]=it.toString()}
            sb.append("win\t").append(w.app.kind).append('\t').append(w.x).append('\t').append(w.y).append('\t')
                .append(w.w).append('\t').append(w.h).append('\t').append(if (w.maximized) 1 else 0).append('\t')
                .append(if (w === focused) 1 else 0)
            for ((k, v) in st) sb.append('\t').append(esc(k)).append('=').append(esc(v))
            sb.append('\n')
        }
        try { env.stateStore.save(sb.toString()) } catch (_: Exception) {}
    }

    /**
     * Set by the platform when it creates the shell, cleared by [restoreSession]. While set, going to the
     * background does not save: the saved session has not been read yet (the platforms read it on the first
     * layout), and saving the still-empty desktop would replace the user's windows and unsaved editor drafts
     * before the first-run intro). Seen on an OPPO phone, where a system overlay paused the app
     * before its first frame.
     */
    @Volatile var awaitingRestore = false

    fun restoreSession() {
        awaitingRestore = false
        val text = try { env.stateStore.load() } catch (_: Exception) { null } ?: return
        val lines = text.split('\n')
        if (lines.firstOrNull() != "v1") return
        var focus: Window? = null
        val restoredIds=HashMap<Int,Int>();val parents=ArrayList<Pair<App,Int>>()
        for (l in lines.drop(1)) {
            val f = l.split('\t')
            if (f.isEmpty()) continue
            if (f[0] == "settings" && f.size > 1) { settings = Settings.decode(f[1]); applyLanguage() }
            if (f[0] != "win" || f.size < 8) continue
            val st = HashMap<String, String>()
            for (kv in f.drop(8)) { val i = kv.indexOf('='); if (i > 0) st[unesc(kv.substring(0, i))] = unesc(kv.substring(i + 1)) }
            // Restoring parses user files (documents, pictures, drafts). An unexpected failure there must
            // cost only that window: the saved session is kept, so it would otherwise end every launch.
            val app = try { Launch.restore(this, f[1], st) } catch (e: Exception) {
                println("TempleOSMobile restore: dropped a ${f[1]} window: $e"); null
            } ?: continue
            val win = open(app, f[6] == "1")
            st["_windowId"]?.toIntOrNull()?.let {restoredIds[it]=win.id}
            st["_parentId"]?.toIntOrNull()?.let {parents.add(app to it)}
            win.x = f[2].toIntOrNull() ?: 0; win.y = f[3].toIntOrNull() ?: 0; win.w = f[4].toIntOrNull() ?: 0; win.h = f[5].toIntOrNull() ?: 0
            clampWindow(win)
            if (f[7] == "1") focus = win
        }
        parents.forEach {(app,parent)->app.navigationParentId=restoredIds[parent]}
        focus?.let { focus(it) }
        relayout(false)
    }

    private fun esc(s: String) = s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("=", "\\e")
    private fun unesc(s: String): String {
        val sb = StringBuilder(); var i = 0
        while (i < s.length) {
            if (s[i] == '\\' && i + 1 < s.length) {
                sb.append(when (s[i + 1]) { 't' -> '\t'; 'n' -> '\n'; 'e' -> '='; else -> s[i + 1] }); i += 2
            } else sb.append(s[i++])
        }
        return sb.toString()
    }

    /** App returning to the foreground: resume programs paused by [onBackground]. */
    fun suspendInput() { releaseInputOwnership(); inputActive = false }
    fun resumeInput() { inputActive = true; syncKeyboard() }

    fun onForeground() {
        resumeInput()
        windows.forEach { it.app.onForeground() }
        invalidate()
    }

    /** App going to background: pause programs, persist everything. */
    fun onBackground() {
        releaseInputOwnership()
        inputActive = false
        windows.forEach { it.app.onBackground() }
        if (!awaitingRestore) saveSession()
        env.tone(0.0)
    }

    companion object {
        val KEY_ROW get() = Touch.keyRow
        /** Window background (frame and client fill): also the color along a window's bottom edge. */
        const val WINDOW_BG = Palette.WHITE
        /** Background of the bottom bars (TempleOS keyboard, key row). */
        const val BAR_BG = Palette.BLACK
        const val LONG_PRESS_MS = 550L
        /** TempleOS's keyboard repeat (HomeLocalize.HC KbdTypeMatic(0)): 250 ms delay, 30 keys per second. */
        const val TYPEMATIC_DELAY_MS = 250L
        const val TYPEMATIC_PERIOD_MS = 33L
        /** Pointer id of taps made for a screen reader ([accessibilityActivate]). */
        const val A11Y_POINTER = 0x7A11
        /**
         * Perf log for benchmarks (launch flag): every running program prints one "TempleOSMobile perf"
         * line per second, as with Show frame rate on, without showing the readout.
         */
        @Volatile var perfLog = false
    }
}

/** User settings persisted with the session. */
class Settings(
    var desktopColor: Int = Palette.DKGRAY,
    var sound: Boolean = true,
    var controlsOpacity: Int = 2,   // 0..3
    var uiScale: Int = 0,           // 0 auto, else device px per logical px
    var crispScaling: Boolean = false,
    var largeTouch: Boolean = false, // V-32: 44-48 dp rows and buttons
    keyboardMode: Int = KEYBOARD_TEMPLEOS,
    /** The in-app UI language (canonical locale id), or "" to follow the device. */
    var language: String = "",
    /** How bundled programs run: [ENGINE_TERRY] (the HolyC interpreter) or [ENGINE_NATIVE] (their Kotlin translation). */
    var engine: Int = ENGINE_TERRY,
) {
    var keyboardMode: Int
        get() = KEYBOARD_TEMPLEOS
        set(@Suppress("UNUSED_PARAMETER") value) {}
    fun encode() = "d=$desktopColor;s=${if (sound) 1 else 0};o=$controlsOpacity;u=$uiScale;c=${if (crispScaling) 1 else 0};t=${if (largeTouch) 1 else 0};k=$keyboardMode;g=$language;e=$engine"
    companion object {
        /** The in-app TempleOS keyboard ([TempleKeyboard]). */
        const val KEYBOARD_TEMPLEOS = 0
        /** The device's own keyboard (international input, dictation, accessibility). */
        const val KEYBOARD_SYSTEM = 1

        /** Pure Terry: every program runs on the HolyC compiler and interpreter. */
        const val ENGINE_TERRY = 0
        /** Pure Kotlin: bundled programs run as their ahead-of-time Kotlin translation (purenative). */
        const val ENGINE_NATIVE = 1

        fun decode(s: String): Settings {
            val m = s.split(';').mapNotNull { val i = it.indexOf('='); if (i > 0) it.substring(0, i) to it.substring(i + 1) else null }.toMap()
            return Settings(
                m["d"]?.toIntOrNull()?.coerceIn(0, 15) ?: Palette.DKGRAY, m["s"] != "0",
                m["o"]?.toIntOrNull()?.coerceIn(0, 3) ?: 2, m["u"]?.toIntOrNull()?.coerceIn(0, 6) ?: 0, m["c"] == "1", m["t"] == "1",
                KEYBOARD_TEMPLEOS,
                // an unknown or stale id falls back to the device language (LocaleResolver ignores it)
                (m["g"] ?: "").filter { it.isLetterOrDigit() || it == '-' }.take(35),
                if (m["e"] == "1") ENGINE_NATIVE else ENGINE_TERRY,
            )
        }
    }
}
