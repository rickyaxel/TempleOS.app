package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/** A finger drag on a program's canvas reaches the program as a held mouse button moving (Maze draws walls). */
class DragTest {
    @Test fun dragDrawsInMaze() {
        val dir = kotlin.io.path.createTempDirectory("drag").toFile()
        val env = HeadlessEnv(dir)
        val sh = Shell(env); sh.resize(360, 640); sh.tick()
        Launch.program(sh, "C:/Demo/Games/Maze.HC", sh.catalog.byPath("C:/Demo/Games/Maze.HC"))
        val prog = sh.focused!!.app as ProgramApp
        val end = System.currentTimeMillis() + 15000
        while (System.currentTimeMillis() < end && prog.kernel.frameCount < 10) { sh.tick(); Thread.sleep(20) }
        sh.tick()
        val c = sh.overlays().first().rect
        var t = 1000L
        val y = c.y + c.h / 3
        sh.pointer(PointerEvent(Ptr.DOWN, c.x + 10, y, timeMs = t))
        Thread.sleep(200); sh.tick()
        for (x in c.x + 10..c.right - 10 step 4) {
            t += 16; sh.pointer(PointerEvent(Ptr.MOVE, x, y, timeMs = t)); sh.tick(); Thread.sleep(16)
        }
        sh.pointer(PointerEvent(Ptr.UP, c.right - 10, y, timeMs = t + 16))
        Thread.sleep(300); sh.tick()
        // count inverted cells in the published frame row band: walls are drawn as inverted spaces
        val buf = ByteArray(640 * 480); prog.kernel.let { k -> synchronized(k.publishLock) { System.arraycopy(k.published, 0, buf, 0, buf.size) } }
        val ty = (y - c.y) * 480 / c.h
        // Maze copies its cell array one text row down (gr.text_base+TEXT_COLS): scan a band
        var lit = 0
        for (yy in ty until minOf(480, ty + 16)) for (x in 0 until 640) if (buf[yy * 640 + x].toInt() != 0) lit++
        println("drag: lit pixels in rows $ty..${ty + 15} = $lit")
        sh.windows.toList().forEach { it.app.close() }
        dir.deleteRecursively()
        assertTrue("a drawn wall spans the row (one cell is 64 px): $lit", lit > 500)
    }

    /** A tap whose press and release arrive together still registers in programs that poll ms.lb (TicTacToe). */
    @Test fun quickTapRegisters() {
        val dir = kotlin.io.path.createTempDirectory("tap").toFile()
        val env = HeadlessEnv(dir)
        val sh = Shell(env); sh.resize(360, 640); sh.tick()
        Launch.program(sh, "C:/Demo/Games/TicTacToe.HC", sh.catalog.byPath("C:/Demo/Games/TicTacToe.HC"))
        val prog = sh.focused!!.app as ProgramApp
        val end = System.currentTimeMillis() + 15000
        while (System.currentTimeMillis() < end && !(prog.kernel.graphicsUsed && prog.kernel.frameCount >= 10)) { sh.tick(); Thread.sleep(20) }
        sh.tick()
        val c = sh.overlays().first().rect
        // centre cell: program pixels 250,250 (cells start at 100, 100 px each)
        val x = c.x + 250 * c.w / 640; val y = c.y + 250 * c.h / 480
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs = 1000)); sh.pointer(PointerEvent(Ptr.UP, x, y, timeMs = 1001))
        val k = prog.kernel
        val board = (k.prog.globals["board"] as io.github.templeosmobile.core.holyc.GlobalSym).addr
        val until = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < until && k.mem.ld1(board + 4) == 0L) { sh.tick(); Thread.sleep(20) }
        val v = k.mem.ld1(board + 4) // I8 board[9]
        sh.windows.toList().forEach { it.app.close() }
        dir.deleteRecursively()
        assertTrue("centre cell taken by the first player", v != 0L)
    }
}
