package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.*

/** Pointer actions delivered by the platform (logical pixel coordinates). */
object Ptr {
    const val DOWN = 0; const val MOVE = 1; const val UP = 2; const val CANCEL = 3
}

class PointerEvent(val action: Int, val x: Int, val y: Int, val id: Int = 0, val timeMs: Long = 0)

/** An entry in a menu (start menu, window menu, program menu). */
class MenuItem(label: () -> String, val enabled: Boolean = true, val checked: Boolean = false, val action: () -> Unit) {
    private val labelText = L10n.Presentation(label)
    val label get() = labelText.value
    constructor(label: String, enabled: Boolean = true, checked: Boolean = false, action: () -> Unit) : this({ label }, enabled, checked, action)
}

/**
 * An element exposed to TalkBack / VoiceOver. The desktop is one custom view, so the shell
 * records what it draws (buttons, rows, keys, text) and the platform publishes these as
 * virtual accessibility nodes; activating one taps its center. [rect] is in logical px.
 */
class A11yNode(val rect: Rect, val label: String, val button: Boolean, val selected: Boolean = false)

/** A program frame the platform draws on top of the shell surface (640x480 indexed). */
interface FrameSource {
    val frameW: Int
    val frameH: Int
    /** Copies the latest frame into [dst] and returns its version. */
    fun copyFrame(dst: ByteArray): Long
    val frameVersion: Long
    val palette: IntArray
    /** The part of the frame to show: the program's TempleOS window (frame pixels). */
    val window: Rect get() = Rect(0, 0, frameW, frameH)
}

/** [src] is the part of the frame shown in [rect] (frame pixels). */
class Overlay(val rect: Rect, val source: FrameSource, val src: Rect = Rect(0, 0, source.frameW, source.frameH))

/**
 * A TempleOS Mobile application hosted in a shell window. Apps draw into the
 * shell surface (client area) and receive pointer gestures and keys.
 */
abstract class App(val shell: Shell) {
    abstract val title: String
    /** Stable kind identifier used for session restore ("terminal", "editor"...). */
    abstract val kind: String
    var dirty = true
    /** Window that opened this child; IDs do not retain an app or its runtime. */
    var navigationParentId: Int? = null
    open fun navigateBack(): Boolean {
        if (navigationParentId == null) return false
        val w = shell.windows.firstOrNull { it.app === this } ?: return false
        shell.close(w); return true
    }
    /** Whether the soft keyboard should be visible while this app is focused. */
    open val wantsKeyboard: Boolean get() = false

    abstract fun draw(s: Surface, r: Rect)

    /** Raw pointer stream; return true to consume (no gesture processing). */
    open fun pointer(e: PointerEvent, r: Rect): Boolean = false
    open fun tap(x: Int, y: Int, r: Rect) {}
    open fun longPress(x: Int, y: Int, r: Rect) {}
    /** Vertical/horizontal drag (scroll) by a pixel delta. */
    open fun scroll(dx: Int, dy: Int, r: Rect) {}
    /** A TempleOS key (ch, scan code with SCF_* flags). */
    open fun key(ch: Int, sc: Long, down: Boolean): Boolean = false
    /**
     * True for a running TempleOS program: keys are a PC keyboard for it (held down until released,
     * SHIFT/CTRL/ALT are keys of their own), not text entry (Kernel/SerialDev/Keyboard.HC).
     */
    open val rawKeys: Boolean get() = false
    open fun text(s: String) {
        if (!InputCharacterPolicy.isByteText(s)) { shell.rejectInput(); return }
        for (c in s) {
            val code = if (c == '\n') '\n'.code else c.code and 0xFF
            val (ch, sc) = Keys.forChar(code)
            key(ch, sc, true); key(ch, sc or Keys.SCF_KEY_UP, false)
        }
    }
    /** Window menu entries (shown by the window's menu button). */
    open fun menu(): List<MenuItem> = emptyList()
    /** Periodic update; return true if the app needs redrawing. */
    open fun tick(nowMs: Long): Boolean = false
    open fun overlays(r: Rect): List<Overlay> = emptyList()
    /** Release controls before focus/modal/lifecycle transitions. */
    open fun releaseInput() {}
    open fun close() {}
    /** Persistable state for session restore. */
    open fun saveState(): Map<String, String> = emptyMap()
    /** True while the app has unsaved changes (closing asks for confirmation). */
    open val unsaved: Boolean get() = false
    open fun onBackground() {}
    open fun onForeground() {}
    /** The window became visible or hidden (portrait shows only the focused window). */
    open fun onVisibility(visible: Boolean) {}

    /**
     * Palette color painted under the system navigation region while this app's window owns the
     * bottom edge ([SystemChrome]). null (the default): what the shell draws along that edge, the
     * window background. Override only for an app that must differ from it.
     */
    open val systemEdgeColor: Int? get() = null

    /** True while focused: the platform defers its bottom-edge gestures (iOS home indicator). */
    open val defersEdgeGestures: Boolean get() = false

    fun invalidate() { dirty = true; shell.invalidate() }

    /**
     * Publishes this app's screen-reader nodes for [r] after [draw] (see [A11yNode]). Apps that
     * record their buttons and text while drawing need nothing more; the default names the window.
     */
    /** Filled by [draw] (the shell clears it before each draw). */
    internal val a11yItems = ArrayList<A11yNode>()
    protected fun a11yButton(r: Rect, label: String, selected: Boolean = false) { a11yItems.add(A11yNode(r, label, true, selected)) }
    protected fun a11yText(r: Rect, label: String) { a11yItems.add(A11yNode(r, label, false)) }
    /** A whole page of text for screen readers (one node). */
    fun a11yPage(r: Rect, text: String) = a11yText(r, text)

    open fun accessibility(r: Rect) {
        if (a11yItems.isEmpty()) shell.a11yText(r, title)
        for (n in a11yItems) if (n.button) shell.a11yButton(n.rect, n.label, n.selected) else shell.a11yText(n.rect, n.label)
    }
}

/** Runs a kernel on its own thread (each program is isolated in its own VM). */
class KernelRunner(val kernel: Kernel, private val onFinished: () -> Unit = {}) {
    private val lock = Object()
    @Volatile var paused = false
        private set
    @Volatile private var running = true
    @Volatile var booted = false
        private set
    @Volatile var bootError: String? = null
        private set
    private var thread: Thread? = null

    fun start(beforeRun: (Kernel) -> Unit) {
        kernel.wakeLock = lock
        val t = Thread(null, {
            try {
                val t0 = System.nanoTime()
                kernel.boot()
                println("TempleOSMobile boot ${kernel.name} ${(System.nanoTime() - t0) / 1_000_000} ms")
                booted = true
                beforeRun(kernel)
            } catch (e: Throwable) {
                bootError = e.message ?: e.toString()
                kernel.console.write("\$RED\$" + L10n.tr8("program.failed_to_start", "reason" to bootError) + "\$FG\$\n")
                running = false
                onFinished()
                return@Thread
            }
            loop()
        }, "HolyC:" + kernel.name, 16L shl 20) // deep compiler/interpreter recursion (as on iOS)
        t.isDaemon = true
        t.priority = Thread.NORM_PRIORITY - 1
        thread = t
        t.start()
    }

    private fun loop() {
        var finishedNotified = false
        while (running) {
            if (paused) { synchronized(lock) { if (paused && running) lock.wait(200) }; continue }
            val wait = try { kernel.step(12_000_000) } catch (e: Throwable) {
                kernel.console.write("\n\$RED\$" + L10n.tr8("program.internal_error", "error" to e) + "\$FG\$\n"); kernel.terminate("internal error"); -1L
            }
            if (wait < 0) {
                if (!finishedNotified) { finishedNotified = true; onFinished() }
                if (!kernel.shellMode) {
                    synchronized(lock) { if (running) lock.wait(250) }
                    continue
                }
            }
            // to the nanosecond (ART waits that precisely): a whole-millisecond wait woke sleeping tasks up to
            // 1 ms late, and Sleep loops (scales, Beep, sound effects) drifted by that much per note
            if (wait > 0) synchronized(lock) { if (running) { val w = minOf(wait, 50_000_000L); lock.wait(w / 1_000_000, (w % 1_000_000).toInt()) } }
        }
    }

    fun post(e: KInput) { kernel.post(e) }

    fun setPaused(p: Boolean) {
        if (p != paused) kernel.clockPaused(p)
        paused = p
        kernel.env.paused(kernel, p)
        synchronized(lock) { lock.notifyAll() }
    }

    fun wake() = synchronized(lock) { lock.notifyAll() }

    /** Stops the program: Break first (lets it clean up), then terminates. */
    fun stop(hard: Boolean = false) {
        if (!hard) {
            kernel.post(KInput.Break)
            wake()
            return
        }
        running = false
        kernel.stopRequested = true
        kernel.vm.interrupt = true
        kernel.silence()
        wake()
        thread?.join(1500)
    }

    val alive get() = running
}
