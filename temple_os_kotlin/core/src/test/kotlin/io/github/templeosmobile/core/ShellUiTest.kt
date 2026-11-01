package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import org.junit.Assert.*
import org.junit.Test

/** Headless shell: real bundled drive, temp overlay, in-memory session store. */
class HeadlessEnv(overlay: File) : ShellEnv {
    override val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), overlay)
    var session: String? = null
    val tones = ArrayList<Double>()
    override val stateStore = object : StateStore {
        override fun load() = session
        override fun save(text: String) { session = text }
    }
    override fun runtimeFile(name: String): ByteArray? {
        val f = if (name == "catalog.json") File(SHARED, "program-manifests/catalog.json") else File(SHARED, "runtime/$name")
        return if (f.exists()) f.readBytes() else null
    }
    override fun tone(freq: Double, atNs: Long) { tones.add(freq) }
    /** Whether the device keyboard is requested. */
    var systemKeyboard = false
    fun showKeyboard(show: Boolean) { systemKeyboard = show }
}

class ShellUiTest {
    private val outDir = File("build/ui-shots").apply { mkdirs() }
    private var t = 1000L

    private fun tap(sh: Shell, x: Int, y: Int) {
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs = t)); t += 50
        sh.pointer(PointerEvent(Ptr.UP, x, y, timeMs = t)); t += 50
        sh.tick()
    }

    private fun waitFor(sh: Shell, ms: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { sh.tick(); if (cond()) return true; Thread.sleep(20) }
        sh.tick(); return cond()
    }

    /** Writes the surface plus program overlays as a PNG for manual inspection. */
    private fun shot(sh: Shell, name: String) {
        sh.tick()
        val s = sh.surface
        val img = BufferedImage(s.width, s.height, BufferedImage.TYPE_INT_RGB)
        for (y in 0 until s.height) for (x in 0 until s.width) img.setRGB(x, y, Palette.STD[s.px[y * s.width + x].toInt() and 15])
        for (o in sh.overlays()) {
            val src = o.source; val buf = ByteArray(src.frameW * src.frameH); src.copyFrame(buf)
            for (y in 0 until o.rect.h) for (x in 0 until o.rect.w) {
                val sx = x * src.frameW / o.rect.w; val sy = y * src.frameH / o.rect.h
                val px = o.rect.x + x; val py = o.rect.y + y
                if (px in 0 until s.width && py in 0 until s.height) img.setRGB(px, py, src.palette[buf[sy * src.frameW + sx].toInt() and 15])
            }
        }
        ImageIO.write(img, "png", File(outDir, "$name.png"))
    }

    private fun newShell(env: HeadlessEnv, w: Int, h: Int): Shell {
        val sh = Shell(env)
        sh.resize(w, h)
        sh.restoreSession()
        sh.tick()
        return sh
    }

    /** A pause before the platform has read the saved session (OPPO: a system overlay before the first frame) must not overwrite it. */
    @Test fun backgroundBeforeRestoreKeepsTheSavedSession() {
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val first = newShell(env, 360, 640)
            Launch.editor(first, null); first.tick()
            first.saveSession()
            val saved = env.session!!
            assertTrue(saved, saved.contains("win\teditor"))
            first.windows.toList().forEach { it.app.close() }

            val sh = Shell(env).also { it.awaitingRestore = true } // as MainActivity / AppDelegate create it
            sh.resize(360, 640)
            sh.onBackground(); sh.onForeground()                    // paused before the first layout
            assertEquals("the stored session is untouched", saved, env.session)
            sh.restoreSession(); sh.tick()
            assertTrue("and restores afterwards", sh.windows.any { it.app is EditorApp })
            sh.onBackground()                                       // after the restore, saving works as before
            assertTrue(env.session!!.contains("win\teditor"))
            sh.windows.toList().forEach { it.app.close() }
        } finally { dir.deleteRecursively() }
    }

    @Test fun portraitAppsOpenAndSessionRestores() {
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val sh = newShell(env, 360, 640)
            shot(sh, "00-empty-desktop")
            assertTrue("catalog loads", sh.catalog.programs.size > 50)

            Launch.files(sh, "C:/Home/Examples"); sh.tick(); shot(sh, "01-files")
            Launch.doc(sh, "C:/Doc/HelpIndex.DD"); sh.tick(); shot(sh, "02-doc")
            Launch.editor(sh, "C:/Home/Examples/Hello.HC"); sh.tick(); shot(sh, "03-editor")
            Launch.god(sh); sh.tick(); shot(sh, "04-god")
            Launch.about(sh); sh.tick(); shot(sh, "05-about")
            Launch.settings(sh); sh.tick(); shot(sh, "06-settings")
            Launch.paint(sh); sh.tick(); shot(sh, "07-paint")
            sh.showStartMenu(); sh.tick(); shot(sh, "08-start-menu")
            sh.back()

            Launch.terminal(sh, "C:/Home", "\"Hello from the terminal %d\\n\", 6*7;")
            val term = sh.focused!!.app as TerminalApp
            assertTrue("terminal runs HolyC: " + term.kernel.console.plainText().takeLast(400),
                waitFor(sh, 20000) { term.kernel.console.plainText().contains("Hello from the terminal 42") })
            shot(sh, "09-terminal")

            val info = sh.catalog.byPath("C:/Home/Examples/Graphics.HC")
            Launch.program(sh, "C:/Home/Examples/Graphics.HC", info)
            val prog = sh.focused!!.app as ProgramApp
            // frames keep running; the published frame holds the drawing (static pictures are
            // published once, not every frame)
            fun drawn(): Int = synchronized(prog.kernel.publishLock) { prog.kernel.published.count { it.toInt() != 0 } }
            assertTrue("graphics program publishes frames", waitFor(sh, 20000) {
                sh.overlays().isNotEmpty() && prog.kernel.frameCount > 2 && prog.kernel.publishedVersion >= 1 && drawn() > 1000 })
            Thread.sleep(500); shot(sh, "10-program")

            val kinds = sh.windows.map { it.app.kind }
            sh.saveSession()
            assertNotNull(env.session)
            sh.windows.toList().forEach { it.app.close() }

            val sh2 = newShell(env, 360, 640)
            assertEquals("session restores the same windows", kinds, sh2.windows.map { it.app.kind })
            assertEquals("program", sh2.focused?.app?.kind)
            sh2.windows.toList().forEach { it.app.close() }

            // landscape layout
            val sh3 = newShell(env, 800, 360)
            sh3.tile(); sh3.tick(); shot(sh3, "11-landscape")
            sh3.windows.toList().forEach { it.app.close() }
        } finally { dir.deleteRecursively() }
    }

    @Test fun paintSavesGrThatRoundTrips() {
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val sh = newShell(env, 360, 640)
            val p = PaintApp(sh); sh.open(p); sh.tick()
            p.pix[10 * 320 + 10] = Palette.RED.toByte()
            val m = p.menu().first { it.label == "Save as..." }; m.action()
            sh.key('\n'.code, Keys.forChar('\n'.code).second, true); sh.tick()
            val saved = env.fs.readFile("C:/Home/Picture.GR")
            assertNotNull("picture saved", saved)
            val p2 = PaintApp(sh, "C:/Home/Picture.GR")
            assertEquals(Palette.RED.toByte(), p2.pix[10 * 320 + 10])
            assertEquals(Palette.WHITE.toByte(), p2.pix[11 * 320 + 10])
        } finally { dir.deleteRecursively() }
    }

    /** The acceptance flow with iOS-style touch ids (a new id per touch): menus must keep working. */
    @Test fun touchIdsPerTouch() {
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val sh = Shell(env); sh.resize(402, 874, 62, 34, 0, 0, 0); sh.tick()
            var tt = 1000L; var id = 1
            fun tapAt(x: Int, y: Int) {
                sh.pointer(PointerEvent(Ptr.DOWN, x, y + 62, id, tt)); tt += 60
                sh.pointer(PointerEvent(Ptr.UP, x, y + 62, id, tt)); tt += 60
                id++; sh.tick()
            }
            // taps go where the layout puts things (MenuMetrics), found through the accessibility nodes
            fun tapNode(label: String) {
                sh.tick() // the nodes are what the last render drew
                val r = sh.accessibilityNodes().firstOrNull { it.label == label }?.rect ?: error("no '$label' in ${sh.accessibilityNodes().map { it.label }}")
                tapAt(r.x + r.w / 2, r.y + r.h / 2 - 62)
            }
            tapNode(tr("topbar.menu")); assertTrue("start menu", sh.popupOpen)
            tapNode(tr("menu.start.editor")); assertEquals("editor", sh.focused?.app?.kind)
            sh.text("\"Edited\\n\";\n")
            tapNode(tr("editor.button.save")); assertTrue("save-as dialog", sh.dialogOpen)
            repeat(40) { sh.key(Keys.CH_BACKSPACE, Keys.SC_BACKSPACE.toLong(), true) }
            sh.text("C:/Home/MyTest.HC\n")
            assertFalse("dialog closed", sh.dialogOpen)
            tapNode(tr("editor.button.run"))
            assertTrue("program ran", waitFor(sh, 20000) { (sh.focused?.app as? ProgramApp)?.isFinished == true })
            tapNode(tr("topbar.menu"))
            assertTrue("start menu opens after RUN", sh.popupOpen)
            sh.windows.toList().forEach { it.app.close() }
        } finally { dir.deleteRecursively() }
    }

    @Test fun largeTouchTargetsMeetMinimumSizeAndPersist() {
        // V-32: at the AUTO scale (1080x2400 px phone -> 360x800 logical) one logical px is ~1 dp
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val sh = Shell(env); sh.resize(360, 800, 24, 16, 0, 0, 0); sh.tick()
            sh.settings.largeTouch = true; Touch.large = true; sh.relayout()
            val mm = sh.metrics
            assertTrue("$mm", ROW_H >= 44 && mm.rowH >= 44 && mm.barH >= 40 && Shell.KEY_ROW >= 44 && mm.chromeH + 8 >= 40)
            var tt = 1000L
            fun tapAt(x: Int, y: Int) {
                sh.pointer(PointerEvent(Ptr.DOWN, x, y, 1, tt)); tt += 60
                sh.pointer(PointerEvent(Ptr.UP, x, y, 1, tt)); tt += 60
                sh.tick()
            }
            // start menu rows are metrics.rowH tall: the title row, then Terminal, HolyC Editor, Files...
            tapAt(20, 24 + mm.barH / 2); assertTrue("start menu", sh.popupOpen)
            val editor=sh.accessibilityNodes().first {it.button && it.label==tr("menu.start.editor")}.rect
            assertTrue(editor.h>=44)
            tapAt(editor.x+30,editor.y+2);assertEquals("editor row near its top edge","editor",sh.focused?.app?.kind)
            tapAt(20, 24 + mm.barH / 2)
            val files=sh.accessibilityNodes().first {it.button && it.label==tr("menu.start.files")}.rect
            assertTrue(files.h>=44)
            tapAt(files.x+30,files.bottom-2);assertEquals("files row near its bottom edge","files",sh.focused?.app?.kind)
            // the editor's buttons are as tall as its header
            assertTrue(EditorApp.HEADER >= 40 && FilesApp.HEADER >= 40)
            sh.saveSession()
            Touch.large = false
            val sh2 = Shell(env); sh2.resize(360, 800, 24, 16, 0, 0, 0); sh2.restoreSession()
            assertTrue("setting persists", sh2.settings.largeTouch && Touch.large)
            sh.windows.toList().forEach { it.app.close() }; sh2.windows.toList().forEach { it.app.close() }
        } finally { Touch.large = false; dir.deleteRecursively() }
    }

    @Test fun landscapeKeyboardKeepsWindowSizeAndLeavesRoomToType() {
        // V-31: 2400x1080 px emulator in landscape = 800x360 logical; the soft keyboard leaves ~90 px
        val dir = kotlin.io.path.createTempDirectory("tosm-ui").toFile()
        try {
            val env = HeadlessEnv(dir)
            val sh = Shell(env); sh.resize(800, 360, 23, 16, 0, 0, 0); sh.tick()
            sh.hideKeyboard()
            sh.settings.largeTouch = true; Touch.large = true; sh.relayout()
            Launch.editor(sh, "C:/Home/Examples/Hello.HC"); sh.tick()
            val win = sh.focused!!
            val before = listOf(win.x, win.y, win.w, win.h)
            sh.hideKeyboard(); sh.tick()
            assertFalse(sh.typingCompact)
            sh.requestKeyboard()
            sh.resize(800, 360, 23, 16, 0, 0, 246); sh.tick() // keyboard up (height measured on the emulator)
            assertTrue("compact typing layout", sh.typingCompact)
            assertTrue("LARGE sizes give way while typing in landscape", Touch.compact && Shell.KEY_ROW == 24)
            val client = sh.clientRect(win)
            assertEquals("no top bar: the editor starts under the status bar", 23, client.y)
            val textRows = (client.h - EditorApp.HEADER) / 8
            assertTrue("$textRows text rows above the keyboard", textRows >= 6)
            // the top bar is hidden: a tap there goes to the editor, not the start menu
            sh.pointer(PointerEvent(Ptr.DOWN, 20, 25, 1, 1000)); sh.pointer(PointerEvent(Ptr.UP, 20, 25, 1, 1050)); sh.tick()
            assertFalse(sh.popupOpen)
            sh.hideKeyboard()
            sh.resize(800, 360, 23, 16, 0, 0, 0); sh.tick() // custom keyboard dismissed
            assertFalse(sh.typingCompact); assertFalse(Touch.compact)
            assertEquals("floating window keeps its size", before, listOf(win.x, win.y, win.w, win.h))
            sh.windows.toList().forEach { it.app.close() }
        } finally { Touch.large = false; Touch.compact = false; dir.deleteRecursively() }
    }
}
