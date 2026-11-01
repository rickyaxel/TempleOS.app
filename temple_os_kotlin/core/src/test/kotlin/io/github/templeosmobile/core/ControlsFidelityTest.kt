package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/**
 * The on-screen game controls through the real touch path (Shell -> GameControls -> kernel),
 * docs/fidelity-audit FA-17..FA-20, on the original programs:
 * - RainDrops opens its valves only while '1'/'2' is physically down (Bt(kbd.down_bitmap,sc_1));
 *   its menu buttons OpenUpper/OpenLower stand for those keys, so they hold them.
 * - Two buttons held by two fingers are released independently (Halogen, DunGen, X-Caliber).
 * - BattleLines reads the wheel (ms.pos.z, set to 25 by MsSet at start).
 * - Titanium tests Bt(kbd.down_bitmap,SC_CTRL): the CTRL button is a held CTRL key.
 * - MOVE mode: a touch moves the pointer without a button (KeepAway, MouseDemo hover).
 */
class ControlsFidelityTest {
    private class Run(val sh: Shell, val k: Kernel, val dir: java.io.File) {
        fun nodes() = sh.accessibilityNodes()
        fun node(label: String) = nodes().first { it.label == label }.rect
        fun waitFor(ms: Long, c: () -> Boolean): Boolean {
            val end = System.currentTimeMillis() + ms
            while (System.currentTimeMillis() < end) { sh.tick(); if (c()) return true; Thread.sleep(16) }
            sh.tick(); return c()
        }
        fun down(label: String, id: Int) { val r = node(label); sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id = id)) ; sh.tick() }
        fun up(label: String, id: Int, r: Rect) { sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id = id)); sh.tick() }
        fun bit(bitmap: String, b: Int): Boolean {
            val a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", bitmap)
            return (k.mem.ld1(a + (b shr 3)) shr (b and 7)) and 1L != 0L
        }
        fun close() { sh.windows.toList().forEach { it.app.close() }; dir.deleteRecursively() }
    }

    private fun launch(path: String, popupOk: Boolean = false, pressAKey: Boolean = false, menuItem: String? = null): Run {
        val dir = kotlin.io.path.createTempDirectory("ctl").toFile()
        val sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); sh.tick()
        Launch.program(sh, path, sh.catalog.byPath(path))
        val p = sh.focused!!.app as ProgramApp
        val r = Run(sh, p.kernel, dir)
        if (popupOk) { assertTrue("$path popup", r.waitFor(20000) { sh.dialogOpen }); sh.key('\n'.code, Keys.forChar('\n'.code).second, true) }
        if (pressAKey) { // the program's own "PRESS A KEY" instructions first (Titanium)
            assertTrue("$path waits for a key", r.waitFor(20000) { p.kernel.console.plainText().contains("PRESS A KEY") })
            val (ch, sc) = Keys.forChar('\n'.code); sh.key(ch, sc, true); sh.key(ch, sc or Keys.SCF_KEY_UP, false)
        }
        assertTrue("$path runs", r.waitFor(20000) { p.kernel.graphicsUsed && p.kernel.frameCount >= 10 })
        sh.invalidate(); sh.tick()
        // the program's menu is read every 15 frames
        if (menuItem != null) assertTrue("$path menu", r.waitFor(5000) { sh.invalidate(); r.nodes().any { it.label == menuItem } })
        return r
    }

    @Test fun rainDropsValveButtonHoldsItsKey() {
        val r = launch("C:/Demo/Games/RainDrops.HC", menuItem = "OpenUpper")
        try {
            val sc1 = Keys.char2ScanCode('1'.code)
            val rect = r.node("OpenUpper")
            r.down("OpenUpper", 1)
            assertTrue("'1' is down while the button is held", r.waitFor(600) { r.bit("down_bitmap", sc1) })
            Thread.sleep(400); r.sh.tick()
            assertTrue("still down after 0.4 s", r.bit("down_bitmap", sc1))
            r.up("OpenUpper", 1, rect)
            assertTrue("released with the finger", r.waitFor(500) { !r.bit("down_bitmap", sc1) })
        } finally { r.close() }
    }

    @Test fun twoFingersReleaseTwoKeys() {
        val r = launch("C:/Demo/Games/Halogen.HC")
        try {
            val up = r.node("Up arrow"); val left = r.node("Left arrow")
            r.down("Up arrow", 1); r.down("Left arrow", 2)
            assertTrue(r.waitFor(500) { r.bit("down_bitmap", Keys.SC_CURSOR_UP) && r.bit("down_bitmap", Keys.SC_CURSOR_LEFT) })
            r.up("Up arrow", 1, up)   // the first finger lifts first: the second must still release its key
            r.up("Left arrow", 2, left)
            assertTrue("both arrows released", r.waitFor(500) { !r.bit("down_bitmap", Keys.SC_CURSOR_UP) && !r.bit("down_bitmap", Keys.SC_CURSOR_LEFT) })
        } finally { r.close() }
    }

    @Test fun battleLinesWheelButtons() {
        val r = launch("C:/Demo/Games/BattleLines.HC", popupOk = true)
        try {
            fun z() = r.k.mem.ld8(r.k.o.msAddr + r.k.o.msPos + 16)
            assertTrue("MsSet(,,25) at start", r.waitFor(3000) { z() == 25L })
            val wu = r.node("Mouse wheel up")
            r.down("Mouse wheel up", 1); r.up("Mouse wheel up", 1, wu)
            assertTrue("one notch up", r.waitFor(1000) { z() == 26L })
            val wd = r.node("Mouse wheel down")
            r.down("Mouse wheel down", 1); r.up("Mouse wheel down", 1, wd)
            r.down("Mouse wheel down", 1); r.up("Mouse wheel down", 1, wd)
            assertTrue("two notches down", r.waitFor(1000) { z() == 24L })
        } finally { r.close() }
    }

    @Test fun titaniumCtrlIsAHeldKey() {
        val r = launch("C:/Apps/Titanium/Run.HC", pressAKey = true)
        try {
            val c = r.node("Control")
            r.down("Control", 1)
            assertTrue("SC_CTRL is down", r.waitFor(500) { r.bit("down_bitmap", Keys.SC_CTRL) })
            r.up("Control", 1, c)
            assertTrue("SC_CTRL is up (a short press is latched for 2 frames)", r.waitFor(3000) { !r.bit("down_bitmap", Keys.SC_CTRL) })
        } finally { r.close() }
    }

    @Test fun moveModeMovesThePointerWithoutAButton() {
        val r = launch("C:/Demo/Games/BattleLines.HC", popupOk = true)
        try {
            // L-CLICK -> R-CLICK -> MOVE
            repeat(2) { val t = r.nodes().first { it.label.startsWith("Touch ") }.rect; r.sh.pointer(PointerEvent(Ptr.DOWN, t.x + 2, t.y + 2, id = 3)); r.sh.pointer(PointerEvent(Ptr.UP, t.x + 2, t.y + 2, id = 3)); r.sh.tick() }
            r.sh.invalidate(); r.sh.tick()
            assertNotNull(r.nodes().firstOrNull { it.label == "Touch moves the pointer" })
            val pic = r.nodes().first { it.label.startsWith("Program picture") }.rect
            val x = pic.x + pic.w / 2; val y = pic.y + pic.h / 2
            r.sh.pointer(PointerEvent(Ptr.DOWN, x, y, id = 4)); r.sh.tick()
            r.sh.pointer(PointerEvent(Ptr.MOVE, x + 20, y + 10, id = 4)); r.sh.tick()
            assertTrue("pointer moved", r.waitFor(500) { r.k.mem.ld8(r.k.o.msAddr + r.k.o.msPos) > 300 })
            assertEquals("no button", 0L, r.k.mem.ld1(r.k.o.msAddr + r.k.o.msLb))
            r.sh.pointer(PointerEvent(Ptr.UP, x + 20, y + 10, id = 4)); r.sh.tick()
        } finally { r.close() }
    }
}
