package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.kernel.*

/**
 * The TempleOS command line. As in TempleOS, the shell language is HolyC:
 * every line is compiled and executed in a persistent kernel, so definitions
 * persist between commands ("I64 x=5;" then "x*2;"). There is no access to
 * the host operating system: commands only reach the sandboxed runtime.
 */
class TerminalApp(shell: Shell, startDir: String = "C:/Home") : App(shell) {
    override val kind = "terminal"
    override val title get() = tr("app.terminal.title")
    override val wantsKeyboard get() = true

    private val env = UiKernelEnv(shell) { shell.focused?.app === this }
    val kernel = Kernel(env, "Terminal", shellMode = true)
    private val runner = KernelRunner(kernel)
    private val frame = KernelFrame(kernel)
    private val view = ConsoleView()
    private val line = StringBuilder()
    private var cursor = 0
    private val history = ArrayList<String>()
    private var histPos = -1
    private var lastVersion = -1L
    private var lastFrame = -1L
    private var showGraphics = true
    private var canvasRect = Rect(0, 0, 0, 0)
    private var shownWindow = Rect(0, 0, Kernel.W, Kernel.H)
    private val still = ByteArray(Kernel.W * Kernel.H)
    @Volatile private var ready = false

    init {
        runner.start { k ->
            k.onShellIdle = { prompt() }
            // the banner is console text (8-bit TempleOS cells): translated when the TempleOS font can show it
            k.console.write("\$PURPLE\$${Brand.APP_NAME} Terminal\$FG\$ - " + L10n.tr8("terminal.banner", "dir" to "\$GREEN\$Dir;\$FG\$", "help" to "\$GREEN\$Help;\$FG\$") + "\n")
            if (startDir != "C:/Home") k.post(KInput.Exec("Cd(\"$startDir\");"))
            else prompt()
            ready = true
        }
    }

    private fun prompt() {
        val dir = try { kernel.mainTask?.let { kernel.curDir(it) } ?: "C:/Home" } catch (_: Exception) { "C:/Home" }
        kernel.console.write("\n\$GREEN\$$dir\$FG\$>")
        shell.post { invalidate() }
    }

    val busy get() = kernel.busy

    // The app in the background: the terminal's kernel (the running command and every task it spawned,
    // such as Noise/Sweep sound tasks) stops using the CPU and the speaker until the app returns, as a
    // program window does (ProgramApp). Without this a `while (TRUE) Snd(..)` typed here kept playing.
    override fun onBackground() { runner.setPaused(true) }
    override fun onForeground() { runner.setPaused(false) }

    override fun tick(nowMs: Long): Boolean {
        env.refresh()
        var d = false
        if (kernel.console.version != lastVersion) { lastVersion = kernel.console.version; d = true }
        if (kernel.graphicsUsed && frame.frameVersion != lastFrame) { lastFrame = frame.frameVersion; d = true }
        if (!busy) kernel.console.setInput(line.toString(), cursor) else if (kernel.console.inputLine == line.toString() && line.isNotEmpty()) {}
        return d
    }

    private fun graphicsVisible() = kernel.graphicsUsed && showGraphics

    override fun draw(s: Surface, r: Rect) {
        if (!ready) { s.fill(r, Palette.WHITE); s.uiText(r.x + 8, r.y + 8, tr("terminal.starting"), Palette.BLUE, r.w - 16); return }
        if (graphicsVisible()) {
            val canvasArea = if (shell.landscape) Rect(r.x, r.y, r.w * 3 / 5, r.h) else Rect(r.x, r.y, r.w, minOf(r.h / 2, r.w * 3 / 4))
            shownWindow = frame.window
            canvasRect = fitAspect(canvasArea, shownWindow.w, shownWindow.h)
            s.fill(canvasArea, Palette.BLACK)
            if (shell.drawsFrameInSurface(this)) { frame.copyFrame(still); s.blitScaled(still, Kernel.W, Kernel.H, canvasRect, shownWindow) }
            val text = if (shell.landscape) Rect(canvasArea.right + 2, r.y, r.right - canvasArea.right - 2, r.h)
                else Rect(r.x, canvasArea.bottom + 2, r.w, r.bottom - canvasArea.bottom - 2)
            view.draw(s, text, kernel.console, true)
            a11yText(canvasRect, tr("terminal.a11y.graphics"))
            a11yText(text, tr("terminal.a11y.output", "text" to Cp437.decode(kernel.console.tailText(6))))
        } else {
            canvasRect = Rect(0, 0, 0, 0)
            view.draw(s, r, kernel.console, true)
            a11yText(r, tr("terminal.a11y.output", "text" to Cp437.decode(kernel.console.tailText(6))))
        }
    }

    override fun overlays(r: Rect) = if (graphicsVisible() && canvasRect.w > 0) listOf(Overlay(canvasRect, frame, shownWindow)) else emptyList()

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        if (!graphicsVisible() || !canvasRect.contains(e.x, e.y) && e.action == Ptr.DOWN) return false
        if (!busy) return false
        val (cx, cy) = canvasToScreen(e.x, e.y, canvasRect, shownWindow)
        kernel.post(KInput.Mouse(cx, cy, e.action == Ptr.DOWN || e.action == Ptr.MOVE, false))
        runner.wake()
        return true
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) { view.scrollBy(dy / 8); invalidate() }

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (busy) {
            // a program is running: keys go to it (Ctrl+C breaks, like Ctrl-Alt-C)
            if (down && (ch == 3 || (ch == 'c'.code && sc and Keys.SCF_CTRL != 0L))) { kernel.post(KInput.Break); runner.wake(); return true }
            kernel.post(KInput.Key(ch, sc, down)); runner.wake(); return true
        }
        if (!down) return true
        view.scrollBack = 0
        val code = (sc and 0x7F).toInt()
        when {
            ch == '\n'.code -> submit()
            ch == Keys.CH_BACKSPACE -> if (cursor > 0) { line.deleteCharAt(cursor - 1); cursor-- }
            code == Keys.SC_DELETE && sc and Keys.SCF_DELETE != 0L -> if (cursor < line.length) line.deleteCharAt(cursor)
            code == Keys.SC_CURSOR_LEFT && ch == 0 -> cursor = maxOf(0, cursor - 1)
            code == Keys.SC_CURSOR_RIGHT && ch == 0 -> cursor = minOf(line.length, cursor + 1)
            code == Keys.SC_HOME && ch == 0 -> cursor = 0
            code == Keys.SC_END && ch == 0 -> cursor = line.length
            code == Keys.SC_CURSOR_UP && ch == 0 -> recall(-1)
            code == Keys.SC_CURSOR_DOWN && ch == 0 -> recall(1)
            ch == Keys.CH_ESC -> { line.setLength(0); cursor = 0 }
            ch == '\t'.code -> complete()
            ch in 32..255 -> { line.insert(cursor, ch.toChar()); cursor++ }
        }
        kernel.console.setInput(line.toString(), cursor)
        invalidate()
        return true
    }

    private fun recall(dir: Int) {
        if (history.isEmpty()) return
        histPos = if (histPos < 0) history.size else histPos
        histPos = (histPos + dir).coerceIn(0, history.size)
        line.setLength(0)
        if (histPos < history.size) line.append(history[histPos])
        cursor = line.length
    }

    /** Tab: complete a file name in the current directory. */
    private fun complete() {
        // search only before the cursor: a separator after it must not start the word
        val start = line.substring(0, cursor).lastIndexOfAny(charArrayOf('"', ' ', '(', ',')) + 1
        val partial = line.substring(start, cursor)
        // cur_dir lives in the program's arena, which the program can overwrite (`Fs->cur_dir=-1;`): a fault
        // here ran on the UI thread and ended the app (the Swift port and prompt() already guarded it)
        val dir = try { kernel.mainTask?.let { kernel.curDir(it) } } catch (_: Exception) { null } ?: "C:/Home"
        val base = if (partial.contains('/')) Paths.normalize(dir, partial.substringBeforeLast('/')) ?: return else dir
        val prefix = partial.substringAfterLast('/')
        val matches = shell.fs.list(base)?.filter { it.name.startsWith(prefix, ignoreCase = true) } ?: return
        if (matches.size == 1) {
            val add = matches[0].name.substring(prefix.length) + if (matches[0].isDir) "/" else ""
            line.insert(cursor, add); cursor += add.length
        } else if (matches.size > 1) {
            kernel.console.write("\n" + matches.joinToString("  ") { it.name } + "\n")
            prompt()
        }
    }

    private fun submit() {
        val cmd = line.toString()
        if (!InputCharacterPolicy.isByteText(cmd)) { shell.rejectInput(); return }
        line.setLength(0); cursor = 0
        kernel.console.setInput(null, 0)
        kernel.console.write(cmd + "\n")
        if (cmd.isBlank()) { prompt(); return }
        if (history.lastOrNull() != cmd) history.add(cmd)
        if (history.size > 200) history.removeAt(0)
        histPos = -1
        // TempleOS convenience: a bare statement without ';' still runs
        val src = if (cmd.trimEnd().endsWith(";") || cmd.trimEnd().endsWith("}") || cmd.trimStart().startsWith("#")) cmd else "$cmd;"
        showGraphics = true
        kernel.post(KInput.Exec(src))
        runner.wake()
    }

    override fun text(s: String) {
        if (!InputCharacterPolicy.isByteText(s)) { shell.rejectInput(); return }
        if (busy) { super.text(s); return }
        for (c in s) {
            if (c == '\n') { key('\n'.code, Keys.special(Keys.SC_ENTER).second, true); continue }
            line.insert(cursor, (c.code and 0xFF).toChar()); cursor++
        }
        kernel.console.setInput(line.toString(), cursor)
        invalidate()
    }

    override fun menu(): List<MenuItem> = listOf(
        MenuItem( { tr("terminal.menu.break") }, enabled = busy) { kernel.post(KInput.Break); runner.wake() },
        MenuItem( { tr(if (showGraphics) "terminal.menu.hide_graphics" else "terminal.menu.show_graphics") }, enabled = kernel.graphicsUsed) { showGraphics = !showGraphics; invalidate() },
        MenuItem( { tr("terminal.menu.clear") }) { kernel.console.clear(); if (!busy) prompt() },
        MenuItem( { tr("menu.paste") }) { shell.pasteClipboard() },
        MenuItem( { tr("terminal.menu.copy_output") }) { shell.env.clipboardSet(Cp437.decode(kernel.console.plainText().takeLast(20000))); shell.showToast( { tr("toast.copied") }) },
        MenuItem( { tr("terminal.menu.commands_help") }) { Launch.doc(shell, "C:/Doc/CmdLineOverview.DD") },
    )

    override fun close() { runner.stop(hard = true); kernel.silence() }

    override fun saveState() = mapOf(
        "dir" to (try { kernel.mainTask?.let { kernel.curDir(it) } } catch (_: Exception) { null } ?: "C:/Home"),
        "hist" to history.takeLast(50).joinToString("\u0001"),
    )

    fun restoreHistory(h: String) { if (h.isNotEmpty()) history.addAll(h.split('\u0001')) }
}
