package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.Task
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * The kernel's pen-table setup (Kernel.setUpPens) against the prelude's HolyC GrSetUpPens it replaces at boot:
 * the arena (every allocation, pen brush, circle table and bit table) and the allocator's state must be identical,
 * and a program drawing with every pen width must draw the same frame.
 */
class PenTablesTest {
    private fun boot(holyC: Boolean): Kernel {
        val k = Kernel(TestEnv(), "pens")
        k.virtualTime = true
        k.holyCPens = holyC
        k.boot()
        return k
    }

    @Test fun nativeSetupLeavesTheSameArenaAsTheHolyCFunction() {
        val a = boot(holyC = true); val b = boot(holyC = false)
        assertEquals("arena size", a.mem.size, b.mem.size)
        assertEquals("high water", a.mem.highWater, b.mem.highWater)
        assertEquals("peak allocated", a.mem.peakAllocated, b.mem.peakAllocated)
        // every allocation, table and brush byte must match; only the unused part of the boot task's memory stack
        // (above its stack pointer) differs, holding whatever the last calls left there: GrSetUpPens' locals in one,
        // DCNew's frames in the other
        val dead = (listOfNotNull(a.current, a.adamTask) + a.tasks).map { (it.msp ushr 3) until ((it.mspBase + Task.MEM_STACK) ushr 3) }
        val diff = (0 until (a.mem.size ushr 3)).filter { a.mem.words[it] != b.mem.words[it] }
        val live = diff.filter { w -> dead.none { w in it } }
        assertTrue("differing live bytes at ${live.take(8).map { it * 8 }}", live.isEmpty())
        // the HolyC version really ran in one and not in the other (the comparison is not of two identical boots)
        assertTrue(a.vm.instructionsExecuted > b.vm.instructionsExecuted + 1_000_000)
    }

    @Test fun everyPenWidthDrawsTheSameFrame() {
        val src = """
            CDC *dc=DCAlias;
            I64 i;
            for (i=0;i<64;i++) {
              dc->color=i&15;
              dc->thick=i;
              GrLine3(dc,10+i*9,40,0,10+i*9+5,400,0);
              GrPlot3(dc,320,240,0);
            }
            DCDel(dc);
            Refresh;
        """.trimIndent().toByteArray()
        fun frame(holyC: Boolean): ByteArray {
            val env = TestEnv()
            val k = Kernel(env, "pens")
            k.virtualTime = true
            k.holyCPens = holyC
            k.boot()
            k.runProgram("C:/Home/Pens.HC", src)
            var steps = 0
            while (!k.finished && steps++ < 2000) if (k.step(50_000_000) < 0) break
            assertNull(k.console.plainText(), k.exitMessage)
            return synchronized(k.publishLock) { k.published.copyOf() }
        }
        val a = frame(true); val b = frame(false)
        assertTrue("the program drew", a.count { it.toInt() != 0 } > 1000)
        assertArrayEquals(a, b)
    }
}
