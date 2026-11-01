package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/** Demo/Graphics/Life.HC: cells drawn with a drag evolve (its animate task completes generations). */
class LifeTest {
    @Test fun drawnCellsEvolve() {
        val dir = kotlin.io.path.createTempDirectory("life").toFile()
        val env = HeadlessEnv(dir)
        val sh = Shell(env); sh.resize(360, 640); sh.tick()
        Launch.program(sh, "C:/Demo/Graphics/Life.HC", sh.catalog.byPath("C:/Demo/Graphics/Life.HC"))
        val prog = sh.focused!!.app as ProgramApp
        val k = prog.kernel
        val end = System.currentTimeMillis() + 15000
        while (System.currentTimeMillis() < end && !(k.graphicsUsed && k.frameCount >= 10)) { sh.tick(); Thread.sleep(20) }
        sh.tick()
        val c = sh.overlays().first().rect
        var t = 1000L
        val y0 = c.y + c.h / 3
        sh.pointer(PointerEvent(Ptr.DOWN, c.x + 20, y0, timeMs = t)); Thread.sleep(100); sh.tick()
        for (x in c.x + 20..c.right - 20 step 4) { t += 16; sh.pointer(PointerEvent(Ptr.MOVE, x, y0 + (x - c.x) / 4, timeMs = t)); sh.tick(); Thread.sleep(16) }
        sh.pointer(PointerEvent(Ptr.UP, c.right - 20, y0, timeMs = t + 16))
        fun green(): Int { val buf = ByteArray(640 * 480); synchronized(k.publishLock) { System.arraycopy(k.published, 0, buf, 0, buf.size) }; return buf.count { it.toInt() == 2 } }
        fun g(name: String) = k.mem.ld8((k.prog.globals[name] as GlobalSym).addr)
        Thread.sleep(500); sh.tick()
        val before = green()
        val curBefore = g("cur_dc")
        var flips = 0; var last = curBefore
        // one generation is ~66M VM instructions (~1 s on a desktop JVM)
        val until = System.currentTimeMillis() + 60000
        while (System.currentTimeMillis() < until && flips < 1) {
            sh.tick(); Thread.sleep(50)
            val cur = g("cur_dc"); if (cur != last) { flips++; last = cur }
        }
        sh.tick(); Thread.sleep(200); sh.tick()
        val after = green()
        println("life: green before=$before after=$after generations=$flips restart=${g("restart")} tasks=${k.tasks.map { "${it.name}:${it.state}" }}")
        sh.windows.toList().forEach { it.app.close() }
        dir.deleteRecursively()
        assertTrue("drawing made green cells: $before", before > 100)
        assertTrue("a generation completed: $flips", flips >= 1)
        assertTrue("the pattern changed: $before -> $after", after != before)
    }
}
