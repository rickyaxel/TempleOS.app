package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Arrow keys reach programs as TempleOS delivers them: sc.u8[0]==SC_CURSOR_UP (no E0 bit,
 * Kernel/SerialDev/Keyboard.HC scan_code_map) and bit SC_CURSOR_UP of kbd.down_bitmap while
 * held; a held on-screen d-pad walks the player in Demo/Games/CastleFrankenstein.HC.
 */
class GameInputTest {
    @Test fun arrowKeysHaveTempleOsScanCodes() {
        val (cu, su) = Keys.special(Keys.SC_CURSOR_UP)
        val k = runHolyC(latin1("I64 sc,ch; ch=GetKey(&sc); \"%d %d %d\\n\",ch,sc.u8[0]==SC_CURSOR_UP,Bt(kbd.down_bitmap,SC_CURSOR_UP);\n")) { kk ->
            kk.post(KInput.Key(cu, su, true))
        }
        assertEquals("0 1 1", k.console.plainText().trim().lines().last())
    }

    @Test fun heldDpadWalksCastleFrankenstein() {
        val dir = kotlin.io.path.createTempDirectory("cf").toFile()
        val sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); sh.tick()
        Launch.program(sh, "C:/Demo/Games/CastleFrankenstein.HC", sh.catalog.byPath("C:/Demo/Games/CastleFrankenstein.HC"))
        val k = (sh.focused!!.app as ProgramApp).kernel
        val end = System.currentTimeMillis() + 20000
        while (System.currentTimeMillis() < end && !(k.graphicsUsed && k.frameCount >= 20)) { sh.tick(); Thread.sleep(20) }
        fun g(n: String) = k.mem.ld8((k.prog.globals[n] as GlobalSym).addr)
        val x0 = g("man_xx"); val y0 = g("man_yy")
        // portrait 360x640: the d-pad "up" button of the controls below the picture
        sh.invalidate(); sh.tick()
        val up = sh.accessibilityNodes().first { it.label == "Up arrow" }.rect
        val ux = up.x + up.w / 2; val uy = up.y + up.h / 2
        sh.pointer(PointerEvent(Ptr.DOWN, ux, uy, id = 1))
        val t0 = System.currentTimeMillis()
        while (System.currentTimeMillis() - t0 < 2000) { sh.tick(); Thread.sleep(16) }
        sh.pointer(PointerEvent(Ptr.UP, ux, uy, id = 1))
        Thread.sleep(300); sh.tick()
        val moved = Math.abs(g("man_xx") - x0) + Math.abs(g("man_yy") - y0)
        sh.windows.toList().forEach { it.app.close() }
        dir.deleteRecursively()
        assertTrue("the player walked (moved $moved map units)", moved > 1000)
    }

    /**
     * Every on-screen control is visible (outside the program picture, which the platform draws on
     * top of the shell) and reaches the game: BomberGolf counts each key in key_cnt. Landscape used
     * to put SPACE/ENTER/ESC under the picture (the left gutter is too narrow for pad + buttons).
     */
    @Test fun bomberGolfControlsAreVisibleAndWork() {
        for ((w, h, large) in listOf(Triple(640, 360, false), Triple(852, 393, false), Triple(852, 393, true), Triple(360, 640, false), Triple(360, 640, true))) {
            val dir = kotlin.io.path.createTempDirectory("bg").toFile()
            val sh = Shell(HeadlessEnv(dir)); sh.settings.largeTouch = large; Touch.large = large; sh.resize(w, h); sh.tick()
            Launch.program(sh, "C:/Demo/Games/BomberGolf.HC", sh.catalog.byPath("C:/Demo/Games/BomberGolf.HC"))
            val k = (sh.focused!!.app as ProgramApp).kernel
            val end = System.currentTimeMillis() + 20000
            while (System.currentTimeMillis() < end && !(k.graphicsUsed && k.frameCount >= 10)) { sh.tick(); Thread.sleep(20) }
            sh.invalidate(); sh.tick()
            val where = "${w}x$h large=$large"
            val nodes = sh.accessibilityNodes()
            val pic = nodes.first { it.label.startsWith("Program picture") }.rect
            val controls = listOf("Up arrow", "Left arrow", "Right arrow", "Down arrow", "Space", "Enter", "Escape", "Touch is left click")
                .map { l -> nodes.firstOrNull { it.label == l } ?: error("$where: no control $l") }
            for (c in controls) {
                val r = c.rect
                val overlap = r.x < pic.right && pic.x < r.right && r.y < pic.bottom && pic.y < r.bottom
                assertFalse("$where: ${c.label} $r is under the picture $pic", overlap)
                assertTrue("$where: ${c.label} $r is on screen", r.x >= 0 && r.y >= 0 && r.right <= w && r.bottom <= h)
            }
            fun keys() = k.mem.ld8((k.prog.globals["key_cnt"] as GlobalSym).addr)
            for (l in listOf("Left arrow", "Space")) {
                val before = keys()
                val r = nodes.first { it.label == l }.rect
                sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id = 1, timeMs = 1)); sh.tick()
                sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id = 1, timeMs = 60))
                val t0 = System.currentTimeMillis()
                while (System.currentTimeMillis() - t0 < 3000 && keys() == before) { sh.tick(); Thread.sleep(20) }
                assertEquals("$where: $l reached the game", before + 1, keys())
            }
            sh.windows.toList().forEach { it.app.close() }
            Touch.large = false
            dir.deleteRecursively()
        }
    }

    /**
     * docs/ui-normalization/TEMPLEOS_PROGRAM_LIFECYCLE_AUTHENTICITY_AUDIT.md: TempleOS never ends a task
     * because of a click outside its window (Adam/WinMgr.HC). A layout with no room for touch controls
     * (landscape gutters under 96 px: split screen, Tile, small windows) kept the previous layout's buttons
     * hit-testable but invisible, so a tap on the black bar beside the picture sent Abort (Shift-Esc) and
     * FlapBat showed "Program ended. Restart from the menu.".
     */
    @Test fun tapsOutsideThePictureDoNotEndTheProgram() {
        val controlLabels = setOf("Space", "Enter", "Escape", "Abort", "Exit", "Touch is left click", "Touch is right click")
        // (name, start size, layout change)
        val cases = listOf<Triple<String, IntArray, (Shell) -> Unit>>(
            Triple("portrait, then a landscape window with narrow gutters", intArrayOf(390, 844, 47, 34)) { it.resize(1100, 834, 24, 20, 0, 0, 0) },
            Triple("phone landscape, then window menu > Tile", intArrayOf(800, 360, 0, 16)) { it.tile() },
        )
        for ((name, size, change) in cases) {
            val dir = kotlin.io.path.createTempDirectory("tap-outside").toFile()
            val sh = Shell(HeadlessEnv(dir)); sh.resize(size[0], size[1], size[2], size[3], 0, 0, 0); sh.tick()
            fun waitFor(ms: Long, c: () -> Boolean): Boolean {
                val end = System.currentTimeMillis() + ms
                while (System.currentTimeMillis() < end) { sh.tick(); if (c()) return true; Thread.sleep(20) }
                sh.tick(); return c()
            }
            Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick() // a second window (Tile, focus)
            Launch.program(sh, "C:/Demo/Games/FlapBat.HC", sh.catalog.byPath("C:/Demo/Games/FlapBat.HC"))
            val win = sh.focused!!
            val p = win.app as ProgramApp
            assertTrue("$name: FlapBat's PopUpOk", waitFor(20000) { sh.dialogOpen })
            sh.key('\n'.code, Keys.forChar('\n'.code).second, true) // OKAY
            assertTrue("$name: playing", waitFor(20000) { p.kernel.graphicsUsed && p.kernel.frameCount >= 10 })
            sh.invalidate(); sh.tick()
            val before = sh.accessibilityNodes().filter { it.button && it.label in controlLabels }.map { it.rect }
            assertTrue("$name: controls shown before the change", before.isNotEmpty())

            change(sh); sh.tick()
            val nodes = sh.accessibilityNodes()
            val pic = nodes.first { it.label.startsWith("Program picture") }.rect
            val client = sh.clientRect(win)
            for (c in nodes.filter { it.button && it.label in controlLabels }) {
                val r = c.rect
                assertFalse("$name: ${c.label} $r is under the picture $pic", r.x < pic.right && pic.x < r.right && r.y < pic.bottom && pic.y < r.bottom)
                assertTrue("$name: ${c.label} $r is inside the window $client", r.x >= client.x && r.y >= client.y && r.right <= client.right && r.bottom <= client.bottom)
            }
            // taps on the window outside the picture (black bars, empty gutters), then where the old buttons were
            var t = 1000L
            fun tap(x: Int, y: Int) {
                sh.pointer(PointerEvent(Ptr.DOWN, x, y, id = 1, timeMs = t)); sh.pointer(PointerEvent(Ptr.UP, x, y, id = 1, timeMs = t + 50)); t += 100
            }
            val shown = nodes.filter { it.button && it.label in controlLabels }.map { it.rect }
            // the 8 px under the chrome row are the window buttons' touch slop (Shell.click), not the program's
            val top = client.y + 8
            fun free(x: Int, y: Int) = y >= top && client.contains(x, y) && shown.none { it.contains(x, y) }
            for (y in top until client.bottom step 6) for (x in client.x until client.right step 6)
                if (!pic.contains(x, y) && free(x, y)) tap(x, y)
            for (r in before) if (free(r.x + r.w / 2, r.y + r.h / 2)) tap(r.x + r.w / 2, r.y + r.h / 2)
            assertFalse("$name: a tap outside the picture ended FlapBat (${p.kernel.exitMessage})", waitFor(1500) { p.isFinished })
            assertSame("$name: the program keeps the focus", win, sh.focused)

            // the program's own exit still works: FlapBat's menu File > Exit is Esc (MenuPush in FlapBat.HC)
            p.menu().first { it.label == "File" }.action()
            sh.tick()
            val exit = sh.accessibilityNodes().first { it.button && it.label == "Exit" }.rect
            tap(exit.x + exit.w / 2, exit.y + exit.h / 2)
            assertTrue("$name: Exit ends FlapBat", waitFor(5000) { p.isFinished })
            assertNull("$name: a normal end", p.kernel.exitMessage)
            sh.invalidate(); sh.tick()
            val msg = sh.accessibilityNodes().firstOrNull { it.label == tr("program.ended") }?.rect
            assertNotNull("$name: the end is announced", msg)
            assertTrue("$name: the end message $msg is under the picture", sh.overlays().none { o ->
                o.rect.x < msg!!.right && msg.x < o.rect.right && o.rect.y < msg.bottom && msg.y < o.rect.bottom })
            sh.windows.toList().forEach { it.app.close() }
            dir.deleteRecursively()
        }
    }
}
