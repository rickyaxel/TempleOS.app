package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/** Editor undo/redo and save, Stop Program, and sound release on close (headless shell). */
class AppBehaviorTest {
    private fun waitFor(sh: Shell, ms: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { sh.tick(); if (cond()) return true; Thread.sleep(20) }
        sh.tick(); return cond()
    }

    private fun shell(): Pair<Shell, HeadlessEnv> {
        val dir = kotlin.io.path.createTempDirectory("apps").toFile().apply { deleteOnExit() }
        val env = HeadlessEnv(dir)
        val sh = Shell(env); sh.resize(360, 640); sh.tick()
        return sh to env
    }

    @Test fun editorUndoRedoSave() {
        val (sh, _) = shell()
        sh.fs.writeFile("C:/Home/Ed.HC", latin1("\"one\\n\";"))
        Launch.editor(sh, "C:/Home/Ed.HC")
        val ed = sh.focused!!.app as EditorApp
        assertEquals("\"one\\n\";", ed.text())
        ed.insert("A")
        Thread.sleep(900) // separate undo steps (edits within 800 ms are grouped)
        ed.insert("B")
        assertEquals("AB\"one\\n\";", ed.text())
        assertTrue(ed.modified)
        ed.undo(); assertEquals("A\"one\\n\";", ed.text())
        ed.undo(); assertEquals("\"one\\n\";", ed.text())
        ed.undo(); assertEquals("nothing left to undo", "\"one\\n\";", ed.text())
        ed.redo(); assertEquals("A\"one\\n\";", ed.text())
        ed.redo(); assertEquals("AB\"one\\n\";", ed.text())
        ed.undo(); ed.undo()
        ed.insert("\"two\\n\";")
        ed.redo(); assertEquals("a new edit clears redo", "\"two\\n\";\"one\\n\";", ed.text())
        assertTrue(ed.save())
        assertFalse(ed.modified)
        assertEquals("\"two\\n\";\"one\\n\";", latin1(sh.fs.readFile("C:/Home/Ed.HC")!!))
        // a second editor on the same file reads the saved text
        sh.windows.toList().forEach { sh.close(it, true) }
        Launch.editor(sh, "C:/Home/Ed.HC")
        assertEquals("\"two\\n\";\"one\\n\";", (sh.focused!!.app as EditorApp).text())
        sh.windows.toList().forEach { sh.close(it, true) }
    }

    @Test fun editorMarksTextHiddenPastTheEdges() {
        // V-25: a 120-column line in a 360 px window, like nano's '$' markers
        val (sh, _) = shell()
        sh.fs.writeFile("C:/Home/Wide.HC", latin1("//" + "a".repeat(118) + "\nU0 Short;\n"))
        Launch.editor(sh, "C:/Home/Wide.HC")
        val ed = sh.focused!!.app as EditorApp
        val c = sh.clientRect(sh.focused!!)
        val gutter = 3 * 8 + 4
        val y0 = c.y + EditorApp.HEADER
        fun grayIn(x: Int, y: Int): Int {
            sh.invalidate(); sh.tick()
            var n = 0
            for (yy in y until y + 8) for (xx in x until x + 8) if (sh.surface.px[yy * sh.surface.width + xx].toInt() == Palette.DKGRAY) n++
            return n
        }
        val lastCol = c.x + gutter + ((c.w - gutter) / 8 - 1) * 8
        assertTrue("right marker on the long line", grayIn(lastCol, y0) > 16)
        assertEquals("no marker on the short line", 0, grayIn(lastCol, y0 + 8))
        assertEquals("no left marker before scrolling", 0, grayIn(c.x + gutter, y0))
        ed.restoreCursor(0, 120)
        assertTrue("left marker after scrolling right", grayIn(c.x + gutter, y0) > 16)
        assertTrue("short line hidden to the left is marked too", grayIn(c.x + gutter, y0 + 8) > 16)
        sh.windows.toList().forEach { sh.close(it, true) }
    }

    @Test fun stopEndsBusyProgram() {
        val (sh, _) = shell()
        sh.fs.writeFile("C:/Home/Busy.HC", latin1("I64 n=0; \"spinning\\n\"; while (TRUE) n++;"))
        Launch.program(sh, "C:/Home/Busy.HC", null)
        val prog = sh.focused!!.app as ProgramApp
        assertTrue("program started", waitFor(sh, 10000) { prog.kernel.console.plainText().contains("spinning") })
        Thread.sleep(300)
        assertFalse(prog.kernel.finished)
        prog.stop()
        assertTrue("Stop ends a busy loop within 3 s", waitFor(sh, 3000) { prog.kernel.finished })
        sh.windows.toList().forEach { sh.close(it, true) }
    }

    /** A held d-pad button auto-repeats like a PC key (TempleOS KbdTypeMatic(0): 250 ms, then 30/s). */
    @Test fun heldDpadAutoRepeats() {
        val (sh, _) = shell()
        val sent = ArrayList<KInput>()
        val gc = GameControls { sent.add(it) }
        gc.draw(Surface(300, 300, sh.font), Rect(0, 0, 300, 300), emptyList(), vertical = true, showDpad = true)
        // vertical layout: the pad starts at (4,4) with 44 px cells; "up" is the middle of the top row
        assertTrue("press hits the up button", gc.pointer(PointerEvent(Ptr.DOWN, 4 + 44 + 20, 4 + 20, id = 7)))
        fun downs() = sent.count { it is KInput.Key && it.down }
        assertEquals(1, downs())
        gc.tick(1000)                 // first tick after the press starts the clock
        gc.tick(1200); assertEquals("no repeat before 250 ms", 1, downs())
        gc.tick(1260); assertEquals("first repeat after 250 ms", 2, downs())
        for (t in 1293..2260 step 33) gc.tick(t.toLong())
        val n = downs()
        assertTrue("about 30 repeats per second: $n", n in 28..34)
        gc.pointer(PointerEvent(Ptr.UP, 4 + 44 + 20, 4 + 20, id = 7))
        assertTrue("release sends key up", sent.last().let { it is KInput.Key && !it.down })
        gc.tick(3000); gc.tick(4000)
        assertEquals("no repeats after release", n, downs())
    }

    /** Landscape: a program picture covered by another window is not composited over it (z-order). */
    @Test fun coveredProgramPictureRespectsStacking() {
        val (sh, _) = shell()
        sh.resize(640, 360); sh.tick()
        Launch.program(sh, "C:/Home/Examples/Graphics.HC", null)
        val progWin = sh.focused!!
        val prog = progWin.app as ProgramApp
        assertTrue("program draws", waitFor(sh, 20000) { prog.kernel.graphicsUsed && sh.overlays().isNotEmpty() })
        val doc = DocViewerApp(sh, "C:/Home/Welcome.DD")
        sh.open(doc, maximized = true); sh.tick()
        assertTrue("the maximized window covers the program: its picture is not an overlay", sh.overlays().none { o -> prog.overlays(sh.clientRect(progWin)).any { it.source === o.source } })
        assertTrue(sh.drawsFrameInSurface(prog))
        sh.focus(progWin); sh.tick()
        assertTrue("on top again: overlay back", waitFor(sh, 3000) { sh.overlays().isNotEmpty() && !sh.drawsFrameInSurface(prog) })
        sh.windows.toList().forEach { sh.close(it, true) }
    }

    /** An idle desktop (terminal + a program waiting for a key) does not ask for redraws every tick. */
    @Test fun idleDesktopDoesNotRedraw() {
        val (sh, _) = shell()
        sh.fs.writeFile("C:/Home/Wait.HC", latin1("\"waiting\\n\"; GetChar;"))
        Launch.terminal(sh)
        val term = sh.focused!!.app as TerminalApp
        Launch.program(sh, "C:/Home/Wait.HC", null)
        val prog = sh.focused!!.app as ProgramApp
        assertTrue(waitFor(sh, 20000) { prog.kernel.console.plainText().contains("waiting") && term.kernel.console.plainText().contains("C:/Home>") })
        Thread.sleep(500); sh.tick()
        var changed = 0; var ticks = 0
        val end = System.currentTimeMillis() + 2000
        while (System.currentTimeMillis() < end) { if (sh.tick()) changed++; ticks++; Thread.sleep(16) }
        println("idle: $changed of $ticks ticks asked for a redraw")
        assertTrue("idle redraws: $changed of $ticks", changed <= 3)
        sh.windows.toList().forEach { sh.close(it, true) }
    }

    @Test fun closingProgramSilencesSound() {
        val (sh, env) = shell()
        sh.fs.writeFile("C:/Home/Beep.HC", latin1("Snd(62); while (TRUE) Sleep(10);"))
        Launch.program(sh, "C:/Home/Beep.HC", null)
        assertTrue("tone started", waitFor(sh, 10000) { env.tones.any { it > 0 } })
        val win = sh.focused!!
        sh.close(win, true)
        assertTrue("silence after close", waitFor(sh, 3000) { env.tones.lastOrNull() == 0.0 })
        val prog = win.app as ProgramApp
        assertTrue("closed program's kernel stops", waitFor(sh, 3000) { prog.isFinished })
    }
}
