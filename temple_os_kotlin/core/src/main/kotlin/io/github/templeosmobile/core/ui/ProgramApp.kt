package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*

/**
 * Runs one HolyC program in its own kernel (isolated VM, arena and thread).
 * Graphics programs show their 640x480 screen scaled with its aspect ratio;
 * console programs show their document. [source] overrides the file contents
 * (used by the editor to run unsaved code).
 */
class ProgramApp(shell: Shell, val path: String, val info: ProgramInfo?, private val source: ByteArray? = null,
                 /** Pure Kotlin: the program's translation; null runs it on the HolyC interpreter (Pure Terry). */
                 val native: io.github.templeosmobile.core.purenative.NativeBinding? = null) : App(shell) {
    override val kind = "program"
    /** Game controls sit near the bottom edge (iOS: the home gesture is deferred while focused). */
    override val defersEdgeGestures get() = true
    override val title: String get() = (info?.title ?: InputCharacterPolicy.display(path.substringAfterLast('/').substringBefore('.'))) +
        (if (native != null) " \u00B7 " + Engines.NATIVE_NAME else "") +
        when { finished -> tr("program.title_suffix.ended"); runner.paused -> tr("program.title_suffix.paused"); else -> "" }

    private val env = UiKernelEnv(shell) { shell.focused?.app === this }
    val kernel = Kernel(env, path.substringAfterLast('/'))
    private val runner = KernelRunner(kernel) { shell.post { invalidate() } }
    private val frame = KernelFrame(kernel)
    private val consoleView = ConsoleView()
    private val controls = GameControls(shell.typematic) { e -> kernel.post(e); runner.wake() }.also { c ->
        c.onWheel = { d -> kernel.post(KInput.Mouse(lastPointer.first, lastPointer.second, lastButtons.first, lastButtons.second, d)); runner.wake() }
    }
    /** Where the last touch put the TempleOS pointer and its buttons (wheel notches keep them). */
    private var lastPointer = Kernel.W / 2 to Kernel.H / 2 // TempleOS starts the pointer mid-screen
    private var lastButtons = false to false
    @Volatile private var finished = false
    private val documentLinks=ArrayList<Pair<Rect,OriginalProgramLink>>()
    private var showConsole = false
    private var keyboardRequested = false
    private var lastConsoleVersion = -1L
    private var lastFrameVersion = -1L
    private var canvasRect = Rect(0, 0, 0, 0)
    /** The program's TempleOS window in the 640x480 screen, as shown in [canvasRect]. */
    private var shownWindow = Rect(0, 0, Kernel.W, Kernel.H)
    private var started = false
    private var wasBooting = false
    /** Per finger: 1 = drives the TempleOS mouse (one finger at a time), 2 = on the controls. */
    private val pointerModes = HashMap<Int, Int>()

    init {
        kernel.native = native
        start()
    }

    /** The engine running this program (Pure Terry or Pure Kotlin), for the UI and session restore. */
    val engineName get() = if (native != null) Engines.NATIVE_NAME else Engines.TERRY_NAME

    private fun start() {
        started = true
        runner.start { k ->
            val data = source ?: shell.fs.readFile(path)
            if (data == null) { k.console.write("\$RED\$" + L10n.tr8("program.file_not_found", "path" to path) + "\$FG\$\n"); k.terminate("not found"); return@start }
            k.runProgram(path, data)
        }
    }

    val isFinished get() = kernel.finished || !runner.alive

    override val rawKeys: Boolean get() = !isFinished

    override val wantsKeyboard: Boolean
        get() = keyboardRequested || (info?.prefersFullKeyboard == true && !isFinished) || kernel.console.inputLine != null ||
            (runner.booted && !kernel.graphicsUsed && !isFinished && kernel.waitingForKey)

    override fun tick(nowMs: Long): Boolean {
        env.refresh()
        controls.tick(nowMs)
        var d = false
        if (isFinished && !finished) { finished = true; controls.releaseAll(); d = true }
        val cv = kernel.console.version
        if (cv != lastConsoleVersion) { lastConsoleVersion = cv; if (!kernel.graphicsUsed || showConsole) d = true }
        if (kernel.graphicsUsed && frame.frameVersion != lastFrameVersion) { lastFrameVersion = frame.frameVersion; d = true }
        // "Starting..." is static: redraw when the boot state changes, not every tick
        val booting = !runner.booted && runner.bootError == null
        if (booting != wasBooting) { wasBooting = booting; d = true }
        if ((showFps || (Shell.perfLog && shell.focused?.app === this)) && nowMs - fpsAt >= 1000) {
            val v = kernel.frameCount // kernel frames (publishedVersion only advances when pixels change)
            val span = maxOf(1, nowMs - fpsAt)
            fps = ((v - fpsVersion) * 1000 / span).toInt()
            if (fpsAt != 0L) println(perfLine(span))
            else shell.uiFrames.take()
            fpsVersion = v; fpsAt = nowMs; perfMark(); if (showFps) d = true
        }
        return d
    }

    // perf log counters at the last line (kernel values are read without a lock: diagnostics only)
    private var perfSpeaker = 0L
    private var perfTicks = 0L
    private var perfTaskNs = 0L
    private var perfComposeNs = 0L
    private var perfFrames = 0L
    private var perfCpuNs = -1L

    private fun perfMark() {
        val st = kernel.frameStats
        perfSpeaker = kernel.speakerChanges; perfTicks = kernel.vm.ticksExecuted; perfTaskNs = st.taskNs; perfComposeNs = st.composeTotalNs; perfFrames = st.frames
        perfCpuNs = shell.env.processCpuNs()
    }

    /**
     * One line per second (Show frame rate, or [Shell.perfLog]): kernel frames per second, mean frame
     * composition, the kernel thread's busy share, speaker changes per second, and the UI thread's
     * frames, longest gap and stalls (UiFrameStats) over the same second; last, the HolyC work done per
     * second (budget ticks: the same count for the same work on Pure Terry and Pure Kotlin).
     */
    private fun perfLine(spanMs: Long): String {
        val st = kernel.frameStats
        val frames = st.frames - perfFrames
        val composeMs = if (frames > 0) (st.composeTotalNs - perfComposeNs) / 1e6 / frames else 0.0
        val busy = 100.0 * ((st.taskNs - perfTaskNs) + (st.composeTotalNs - perfComposeNs)) / (spanMs * 1e6)
        val (uiFrames, uiGap, uiJanks) = shell.uiFrames.take()
        val cpuNow = shell.env.processCpuNs()
        // the whole app's CPU (UI, audio, kernel and task threads) per second of wall time, in percent of one core
        val cpu = if (cpuNow >= 0 && perfCpuNs >= 0) 100.0 * (cpuNow - perfCpuNs) / (spanMs * 1e6) else -1.0
        return "TempleOSMobile perf program=${info?.id ?: path} engine=${if (native != null) "native" else "terry"} fps=$fps compose_ms=%.1f busy_pct=%.0f cpu_pct=%.0f speaker_per_s=%d ui_fps=%d ui_max_gap_ms=%.0f ui_janks=%d ticks_per_s=%d".format(
            java.util.Locale.ROOT, composeMs, busy, cpu, (kernel.speakerChanges - perfSpeaker) * 1000 / spanMs, uiFrames * 1000 / spanMs.toInt(), uiGap, uiJanks,
            (kernel.vm.ticksExecuted - perfTicks) * 1000 / spanMs)
    }

    // Frame-rate readout (window menu > Show frame rate): kernel frames per second.
    private var showFps = false
    private var fps = 0
    private var fpsAt = 0L
    private var fpsVersion = 0L

    private fun layout(r: Rect, win: Rect): Pair<Rect, Rect> {
        // returns (canvas, controls); the canvas keeps the shape of the program's window
        val portrait = !shell.landscape
        if (portrait) {
            val canvas = fitAspect(Rect(r.x, r.y, r.w, minOf(r.h, (r.w.toLong() * win.h / maxOf(1, win.w)).toInt())), win.w, win.h)
            return canvas to Rect(r.x, canvas.bottom + 4, r.w, r.bottom - canvas.bottom - 4)
        }
        val canvas = fitAspect(r, win.w, win.h)
        val side = (r.w - canvas.w) / 2
        return if (side >= 96) canvas to Rect(r.x, r.y, side - 4, r.h) else canvas to Rect(0, 0, 0, 0)
    }

    private val still by lazy { ByteArray(Kernel.W * Kernel.H) }

    override fun draw(s: Surface, r: Rect) {
        documentLinks.clear()
        if (!runner.booted && runner.bootError == null) {
            s.fill(r, Palette.WHITE)
            s.uiText(r.x + 8, r.y + 8, tr("program.starting", "title" to title), Palette.BLUE, r.w - 16)
            return
        }
        if (!kernel.graphicsUsed || showConsole) {
            consoleView.draw(s, r, kernel.console, !isFinished)
            canvasRect = Rect(0, 0, 0, 0)
            controls.clearLayout()
            a11yText(r, "$title: " + kernel.console.tailText(6))
            return
        }
        s.fill(r, Palette.BLACK)
        val win = frame.window
        val (canvas, ctl) = layout(r, win)
        canvasRect = canvas
        shownWindow = win
        if (shell.drawsFrameInSurface(this) || finished) {
            // no overlay under popups or covering windows, or once the program ended (the end message
            // below must not be hidden by the picture): show the last frame in the surface instead
            frame.copyFrame(still)
            s.blitScaled(still, Kernel.W, Kernel.H, canvas, win)
        }
        if (ctl.w > 0 && ctl.h > 0) {
            if (shell.landscape) {
                // left gutter: d-pad; right gutter: action buttons (they do not fit beside the pad)
                val right = Rect(canvas.right + 4, r.y, r.right - canvas.right - 4, r.h)
                controls.draw(s, ctl, kernel.menuSnapshot, vertical = false, showDpad = wantsDpad(), actionArea = right, info = info)
            } else controls.draw(s, ctl, kernel.menuSnapshot, vertical = true, showDpad = wantsDpad(), info = info)
        } else controls.clearLayout() // no room for controls: only what is drawn may take touches
        for(link in kernel.console.spriteLinks(maxOf(1,win.w/8))) {
            val action=OriginalProgramLink.parse(link.format,Paths.parent(path)) ?: continue
            val hit=Rect(canvas.x+link.x*canvas.w/win.w,canvas.y+link.y*canvas.h/win.h,maxOf(1,link.width*canvas.w/win.w),maxOf(1,link.height*canvas.h/win.h)).intersect(canvas)
            if(hit.w>0 && hit.h>0) {documentLinks.add(hit to action);a11yButton(hit,action.label)}
        }
        a11yText(canvas, tr("program.a11y.picture", "title" to title))
        controls.accessibility { cr, label, on -> a11yButton(cr, label, on) }
        if (showFps) s.text(canvas.right - 56, canvas.bottom + 2, "%3d FPS".format(java.util.Locale.ROOT, fps), Palette.YELLOW, Palette.BLACK)
        if (isFinished) {
            // the exit reason is the kernel's own (HolyC/TempleOS) text; only the frame is translated
            val msg = kernel.exitMessage?.let { tr("program.ended_with", "reason" to it.take(40)) } ?: tr("program.ended")
            s.uiText(r.x + 4, r.bottom - 10, msg, Palette.YELLOW, r.w - 8, Palette.BLACK)
            a11yText(Rect(r.x, r.bottom - 10, r.w, 10), msg)
        }
    }

    private fun wantsDpad() = info?.usesArrows ?: true

    override fun overlays(r: Rect): List<Overlay> =
        if (kernel.graphicsUsed && !showConsole && canvasRect.w > 0 && !finished) listOf(Overlay(canvasRect, frame, shownWindow)) else emptyList()

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        val link=documentLinks.firstOrNull {it.first.contains(e.x,e.y)}
        if(link!=null) {if(e.action==Ptr.UP) Launch.program(shell,link.second.path,shell.catalog.byPath(link.second.path));return true}
        if (!kernel.graphicsUsed || showConsole) return false
        // each finger keeps its role until it lifts (two buttons held at once, or a button and the picture)
        if (e.action == Ptr.DOWN) {
            pointerModes[e.id] = when {
                controls.pointer(e) -> 2
                canvasRect.contains(e.x, e.y) && 1 !in pointerModes.values -> 1
                else -> 0
            }
            if (pointerModes[e.id] == 2) { invalidate(); return true }
        }
        val mode = pointerModes[e.id] ?: 0
        if (e.action == Ptr.UP || e.action == Ptr.CANCEL) pointerModes.remove(e.id)
        if (mode == 2) { controls.pointer(e); invalidate(); return true }
        if (mode == 1) {
            val (cx, cy) = canvasToScreen(e.x, e.y, canvasRect, shownWindow)
            lastPointer = cx to cy
            val pressed = e.action == Ptr.DOWN || e.action == Ptr.MOVE
            lastButtons = (pressed && controls.clickMode == 0) to (pressed && controls.clickMode == 1)
            kernel.post(KInput.Mouse(cx, cy, lastButtons.first, lastButtons.second))
            runner.wake()
            return true
        }
        return false
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        if (!kernel.graphicsUsed || showConsole) { consoleView.scrollBy(dy / 8); invalidate() }
    }

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (isFinished) return false
        kernel.post(KInput.Key(ch, sc, down))
        runner.wake()
        return true
    }

    override fun menu(): List<MenuItem> {
        val items = ArrayList(originalMenuItems(""))
        if (!isFinished) items.add(MenuItem( { tr(if (runner.paused) "program.menu.resume" else "program.menu.pause") }) { runner.setPaused(!runner.paused); controls.releaseAll(); invalidate() })
        if (!isFinished) items.add(MenuItem( { tr("menu.stop_program") }) { stop() })
        items.add(MenuItem( { tr("program.menu.restart") }) { restart() })
        if (kernel.graphicsUsed) items.add(MenuItem( { tr(if (showConsole) "program.menu.show_screen" else "program.menu.show_console") }) { showConsole = !showConsole; invalidate() })
        items.add(MenuItem( { tr(if (shell.templeKeyboardShown) "program.menu.hide_keyboard" else "program.menu.show_keyboard") }) {
            keyboardRequested = !shell.templeKeyboardShown
            if (keyboardRequested) shell.requestKeyboard() else shell.hideKeyboard()
            shell.invalidate()
        })
        if(runner.booted && isFinished && kernel.documents.canExport()) items.add(MenuItem( { tr("menu.save_as") }) {
            shell.showDialog(Dialog.input( { tr("editor.dialog.save_as") },"C:/Home/"+path.substringAfterLast('/').substringBefore('.')+".DD") {target ->
                if(target!=null) try {kernel.documents.export(target);shell.showToast( { tr("toast.saved","path" to target) })} catch(e:FsError) {shell.showToast( { e.localized() })} catch(e:Exception) {shell.showToast( { e.message.orEmpty() })}
            })
        })
        items.add(MenuItem( { tr("menu.edit_source") }) { Launch.editor(shell, path) })
        if (kernel.graphicsUsed) items.add(MenuItem( { tr("program.menu.show_frame_rate") }, checked = showFps) { showFps = !showFps; fpsAt = 0; invalidate() })
        if (info != null) items.add(MenuItem( { tr("program.menu.about") }) {
            val license = { if (info.license.startsWith("Public domain")) tr("catalog.license.public_domain") else tr("catalog.license.project") }
            shell.showDialog(Dialog.confirm( { info.title }, { tr("program.about.details", "author" to info.author, "license" to license(), "source" to info.source, "file" to info.path) +
                (if (info.localizedDescription.isNotEmpty()) "\n\n${info.localizedDescription}" else "") +
                (if (info.note.isNotEmpty()) "\n\n" + tr("program.about.compatibility", "status" to tr("catalog.status.${info.status}"), "note" to info.localizedNote) else "") }, { tr("button.ok") }) {})
        })
        return items
    }

    /** Task menu state and MenuPush/MenuPop replacements stay owned by the source. */
    private fun originalMenuItems(parent:String):List<MenuItem> = kernel.menuSnapshot
        .filter {it.path.substringBeforeLast('/',"")==parent}.map {m->
            MenuItem( { m.label },checked=m.checked) {
                val current=kernel.menuSnapshot.firstOrNull {it.path==m.path}
                if(current!=null) {
                    if(current.isDir) shell.showMenu(originalMenuItems(current.path),4,shell.insetTop+shell.barH, { current.label })
                    else {kernel.post(KInput.Raw(current.msgCode.toInt(),current.a1,current.a2));runner.wake()}
                }
            }
        }

    fun stop() {
        if (isFinished) return
        runner.stop(hard = false)
        // escalate if the program does not end within 1.5 s (spec: Stop raises Break first)
        Thread {
            Thread.sleep(1500)
            if (!kernel.finished) runner.stop(hard = true)
            shell.post { invalidate() }
        }.apply { isDaemon = true }.start()
        controls.releaseAll()
    }

    private fun restart() {
        val win = shell.windows.firstOrNull { it.app === this } ?: return
        close()
        shell.close(win, force = true)
        Launch.program(shell, path, info)
    }

    // Automatic pausing (separate from the user's Pause): the program stops using
    // CPU while the app is in the background or its window is not visible.
    private var autoPaused = false
    private var inBackground = false
    private var hidden = false

    private fun syncAutoPause() {
        val want = inBackground || hidden
        if (want && !isFinished && !runner.paused) { controls.releaseAll(); runner.setPaused(true); autoPaused = true }
        else if (!want && autoPaused) { autoPaused = false; runner.setPaused(false) }
    }

    override fun onBackground() { controls.releaseAll(); inBackground = true; syncAutoPause() }
    override fun onForeground() { inBackground = false; syncAutoPause() }
    override fun onVisibility(visible: Boolean) { hidden = !visible; syncAutoPause() }

    /**
     * Closing the window is TempleOS's close box (Adam/WinMgr.HC): a terminal task gets SHIFT-ESC, so
     * the program ends its own way (FlapBat, Talons and others save their best scores then). The
     * window is gone at once; a program still running after [CLOSE_GRACE_MS] (or paused) is stopped.
     */
    override fun releaseInput() {
        controls.releaseAll(); pointerModes.clear()
        if (lastButtons.first || lastButtons.second) {
            lastButtons = false to false
            kernel.post(KInput.Mouse(lastPointer.first, lastPointer.second, false, false)); runner.wake()
        }
    }

    override fun close() {
        controls.releaseAll()
        kernel.silence()
        if (isFinished || runner.paused) { runner.stop(hard = true); return }
        kernel.post(KInput.Key(Keys.CH_SHIFT_ESC, Keys.SC_ESC.toLong() or Keys.SCF_SHIFT, true))
        kernel.post(KInput.Key(Keys.CH_SHIFT_ESC, Keys.SC_ESC.toLong() or Keys.SCF_SHIFT or Keys.SCF_KEY_UP, false))
        runner.wake()
        Thread {
            val end = System.currentTimeMillis() + CLOSE_GRACE_MS
            while (!kernel.finished && System.currentTimeMillis() < end) Thread.sleep(20)
            runner.stop(hard = true)
        }.apply { isDaemon = true }.start()
    }

    companion object {
        const val CLOSE_GRACE_MS = 1000L
    }

    override fun saveState() = mapOf("path" to path, "id" to (info?.id ?: ""), "engine" to if (native != null) "native" else "terry")
}

/** Bytes of a file's text part (before the DolDoc binary section). */
fun textPart(data: ByteArray): String {
    val end = data.indexOf(0.toByte()).let { if (it < 0) data.size else it }
    return latin1(data, 0, end)
}
