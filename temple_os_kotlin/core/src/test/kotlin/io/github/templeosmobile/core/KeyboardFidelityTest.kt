package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Keyboards for a running program (docs/fidelity-audit FA-21, FA-22): physical keys and the
 * on-screen TempleOS keyboard behave like a PC keyboard under TempleOS (Kernel/SerialDev/Keyboard.HC):
 * a key stays down until released, repeats at KbdTypeMatic(0)'s rate (250 ms, then 30/s), SHIFT/CTRL
 * are keys of their own, and SHIFT-ESC can be typed.
 */
class KeyboardFidelityTest {
    /** Counts 'a' key-downs and keeps the last ASCII; stays running. */
    private val probe = "I64 n=0,last=0,ch,sc;\nwhile (TRUE) {while (ScanKey(&ch,&sc)) {last=ch; if (ch=='a') n++;} Refresh;}\n"

    private class Run(val sh: Shell, val k: Kernel, val app: ProgramApp, val dir: java.io.File) {
        fun waitFor(ms: Long, c: () -> Boolean): Boolean {
            val end = System.currentTimeMillis() + ms
            while (System.currentTimeMillis() < end) { sh.tick(); if (c()) return true; Thread.sleep(10) }
            sh.tick(); return c()
        }
        fun g(n: String) = k.mem.ld8((k.prog.globals[n] as GlobalSym).addr)
        fun bit(b: Int): Boolean { val a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", "down_bitmap"); return (k.mem.ld1(a + (b shr 3)) shr (b and 7)) and 1L != 0L }
        fun close() { sh.windows.toList().forEach { it.app.close() }; dir.deleteRecursively() }
    }

    private fun start(): Run {
        val dir = kotlin.io.path.createTempDirectory("kbd").toFile()
        val sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); sh.tick()
        sh.fs.writeFile("C:/Home/Probe.HC", latin1(probe))
        Launch.program(sh, "C:/Home/Probe.HC", null)
        val app = sh.focused!!.app as ProgramApp
        val r = Run(sh, app.kernel, app, dir)
        assertTrue("probe runs", r.waitFor(20000) { app.kernel.prog.globals.containsKey("n") && app.kernel.frameCount > 5 })
        return r
    }

    @Test fun physicalKeyHoldsAndRepeatsAtTempleOsRate() {
        val r = start()
        try {
            val (ch, sc) = Keys.forChar('a'.code)
            r.sh.hardwareKey(ch, sc, true)
            val t0 = System.currentTimeMillis()
            // platform auto-repeats are dropped: the shell repeats
            repeat(20) { r.sh.hardwareKey(ch, sc, true, platformRepeat = true) }
            assertTrue(r.waitFor(500) { r.bit(sc.toInt() and 0xFF) })
            while (System.currentTimeMillis() - t0 < 1000) { r.sh.tick(); Thread.sleep(5) }
            r.sh.hardwareKey(ch, sc, false)
            assertTrue("released", r.waitFor(1000) { !r.bit(sc.toInt() and 0xFF) })
            r.waitFor(300) { false }
            val n = r.g("n")
            // 1 press + (1000-250)/33 = ~23 repeats at TempleOS's rate (Android would have sent 20 more)
            assertTrue("key-downs in 1 s held: $n", n in 18..28)
        } finally { r.close() }
    }

    /** A PC keyboard has one typematic key: pressing B stops A's repeats, and releasing B does not resume them. */
    @Test fun onlyTheLastPressedKeyRepeats() {
        val r = start()
        try {
            val (ca, sa) = Keys.forChar('a'.code)
            val (cb, sb) = Keys.forChar('b'.code)
            fun hold(ms: Long) { val t = System.currentTimeMillis(); while (System.currentTimeMillis() - t < ms) { r.sh.tick(); Thread.sleep(5) } }
            r.sh.hardwareKey(ca, sa, true)
            hold(600)
            assertTrue("A repeats alone", r.waitFor(300) { r.g("n") >= 5 })
            r.sh.hardwareKey(cb, sb, true)
            r.waitFor(200) { r.g("last") == 'b'.code.toLong() }
            val n1 = r.g("n")
            hold(600)
            r.sh.hardwareKey(cb, sb, false)
            hold(500)
            r.sh.hardwareKey(ca, sa, false)
            r.waitFor(200) { false }
            assertEquals("A stopped repeating once B was pressed", n1, r.g("n"))
        } finally { r.close() }
    }

    /** Adam/WinMgr.HC close box: a terminal task gets SHIFT-ESC, so the program can save before it ends. */
    @Test fun closingTheWindowSendsShiftEscFirst() {
        val dir = kotlin.io.path.createTempDirectory("close").toFile()
        try {
            val sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); sh.tick()
            sh.fs.writeFile("C:/Home/Closer.HC", latin1("I64 c;do c=GetChar(,FALSE); while (c!=CH_SHIFT_ESC);\nRegWrite(\"Test/Closer\",\"I64 closed=1;\\n\");\n"))
            Launch.program(sh, "C:/Home/Closer.HC", null)
            val app = sh.focused!!.app as ProgramApp
            val end = System.currentTimeMillis() + 20000
            while (System.currentTimeMillis() < end && !(app.kernel.waitingForKey)) { sh.tick(); Thread.sleep(10) }
            sh.close(sh.windows.first { it.app === app }, force = true)
            val end2 = System.currentTimeMillis() + 3000
            while (System.currentTimeMillis() < end2 && !app.kernel.finished) Thread.sleep(10)
            assertTrue("program ended", app.kernel.finished)
            val reg = sh.fs.readFile("C:/Home/Registry.HC")?.let { latin1(it) } ?: ""
            assertTrue("the program saw SHIFT-ESC and saved: $reg", reg.contains("closed=1"))
        } finally { dir.deleteRecursively() }
    }

    @Test fun physicalCtrlIsAKeyForPrograms() {
        val r = start()
        try {
            val (ch, sc) = Keys.special(Keys.SC_CTRL, ctrl = true)
            r.sh.hardwareKey(ch, sc, true)
            assertTrue("SC_CTRL down", r.waitFor(500) { r.bit(Keys.SC_CTRL) })
            r.sh.hardwareKey(ch, sc, false)
            assertTrue("SC_CTRL up", r.waitFor(1000) { !r.bit(Keys.SC_CTRL) })
        } finally { r.close() }
    }

    @Test fun focusChangeReleasesHeldPhysicalKeys() {
        val r = start()
        try {
            val (ch, sc) = Keys.special(Keys.SC_CURSOR_UP)
            r.sh.hardwareKey(ch, sc, true)
            assertTrue(r.waitFor(500) { r.bit(Keys.SC_CURSOR_UP) })
            Launch.terminal(r.sh)
            // the hidden program is paused; back in front it has the key-up and the key is not held
            r.sh.focus(r.sh.windows.first { it.app === r.app })
            assertTrue("released when another window took the focus", r.waitFor(1500) { !r.bit(Keys.SC_CURSOR_UP) })
        } finally { r.close() }
    }

    private fun showKeyboard(r: Run) {
        r.app.menu().first { it.label == tr("program.menu.show_keyboard") }.action()
        r.sh.invalidate(); r.sh.tick()
    }

    private fun key(r: Run, label: String) = r.sh.accessibilityNodes().first { it.label == label && it.button }.rect

    @Test fun onScreenKeyIsHeldWhileTouched() {
        val r = start()
        try {
            showKeyboard(r)
            val a = key(r, "a")
            val sc = Keys.char2ScanCode('a'.code)
            r.sh.pointer(PointerEvent(Ptr.DOWN, a.x + a.w / 2, a.y + a.h / 2, id = 1, timeMs = r.sh.env.nowMs())); r.sh.tick()
            assertTrue("'a' goes down on touch", r.waitFor(500) { r.bit(sc) })
            r.waitFor(700) { false }
            assertTrue("still held after 0.7 s", r.bit(sc))
            assertTrue("repeats at the TempleOS rate while held", r.g("n") >= 10)
            r.sh.pointer(PointerEvent(Ptr.UP, a.x + a.w / 2, a.y + a.h / 2, id = 1, timeMs = r.sh.env.nowMs())); r.sh.tick()
            assertTrue("up on release", r.waitFor(1000) { !r.bit(sc) })
        } finally { r.close() }
    }

    @Test fun onScreenShiftEscIsAbort() {
        val r = start()
        try {
            showKeyboard(r)
            fun tap(label: String) {
                val k = key(r, label)
                r.sh.pointer(PointerEvent(Ptr.DOWN, k.x + k.w / 2, k.y + k.h / 2, id = 2, timeMs = r.sh.env.nowMs())); r.sh.tick()
                r.sh.pointer(PointerEvent(Ptr.UP, k.x + k.w / 2, k.y + k.h / 2, id = 2, timeMs = r.sh.env.nowMs())); r.sh.tick()
            }
            tap("Shift")
            assertTrue("a running program sees SHIFT go down with the latch", r.waitFor(500) { r.bit(Keys.SC_SHIFT) })
            tap("Escape")
            assertTrue("SHIFT-ESC (CH_SHIFT_ESC) reached the program", r.waitFor(1000) { r.g("last") == Keys.CH_SHIFT_ESC.toLong() })
            assertTrue("the one-shot SHIFT is released", r.waitFor(1000) { !r.bit(Keys.SC_SHIFT) })
        } finally { r.close() }
    }
}
