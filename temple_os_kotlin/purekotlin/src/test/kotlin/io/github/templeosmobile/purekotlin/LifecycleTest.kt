package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.Kernel
import io.github.templeosmobile.core.purenative.NativeRuntime
import org.junit.Assert.*
import org.junit.Test

/**
 * Engine lifecycle and isolation: a native program's task threads end with it (closed, killed mid-slice,
 * or ended by itself), the speaker is silenced, and switching engines back and forth in one process
 * leaves nothing behind that changes the next run.
 */
class LifecycleTest {
    private fun nativeThreads() = Thread.getAllStackTraces().keys.count { it.isAlive && it.name.startsWith("HolyC-native:") }

    /** Waits up to 3 s for the condition (a thread's last instructions after it has handed back). */
    private fun eventually(what: String, cond: () -> Boolean) {
        val end = System.nanoTime() + 3_000_000_000L
        while (!cond()) {
            if (System.nanoTime() > end) fail(what)
            Thread.sleep(5)
        }
    }

    private fun runtime(k: Kernel) = k.vm.engine as NativeRuntime

    @Test
    fun closingAProgramEndsItsTaskThreads() {
        val before = nativeThreads()
        // BomberGolf: a main task plus Noise/Sweep sound tasks, parked in Sleep/Refresh when closed
        val (k, env) = bootProgram("C:/Demo/Games/BomberGolf.HC", Engine.NATIVE)
        advanceTo(k, 2500)
        val rt = runtime(k)
        assertTrue("task threads while running", rt.liveThreads > 0)
        k.terminate("closed")
        eventually("task threads ended: ${rt.liveThreads} left") { rt.liveThreads == 0 }
        eventually("no HolyC-native threads left") { nativeThreads() == before }
        assertEquals("speaker silenced at close", 0.0, env.sound.last().second, 0.0)
    }

    @Test
    fun aProgramThatEndsItselfLeavesNoThreads() {
        val before = nativeThreads()
        val (k, _) = bootProgram("C:/Home/Examples/Hello.HC", Engine.NATIVE)
        val rt = runtime(k)
        var ms = 0L
        while (!k.finished && ms < 20_000) { ms += 100; if (!advanceTo(k, ms)) break }
        k.terminate("done")
        eventually("task threads ended: ${rt.liveThreads} left") { rt.liveThreads == 0 }
        eventually("no HolyC-native threads left") { nativeThreads() == before }
    }

    @Test
    fun repeatedOpenCloseDoesNotLeak() {
        val before = nativeThreads()
        for (i in 0 until 12) {
            val (k, _) = bootProgram(if (i % 2 == 0) "C:/Demo/Graphics/Bounce.HC" else "C:/Demo/Games/Squirt.HC", Engine.NATIVE)
            advanceTo(k, 300L + 37 * i) // closed at different points of a slice
            k.terminate("closed")
        }
        eventually("no HolyC-native threads left: ${nativeThreads() - before}") { nativeThreads() == before }
    }

    @Test
    fun switchingEnginesLeavesNoState() {
        // T N T N in one process: the same results each time, so neither engine leaves state for the other
        val s = Script.sweep(1500)
        val runs = listOf(Engine.TERRY, Engine.NATIVE, Engine.TERRY, Engine.NATIVE).map { e ->
            runScript("C:/Demo/Games/BomberGolf.HC", e, s).also { it.kernel.terminate("done") }
        }
        for (i in 1 until runs.size) assertNull("run $i", compareRuns(runs[0], runs[i]))
    }
}
