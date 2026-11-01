package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * A program that does not fit the device's program memory (Talons at the 32 MiB class) fails the same way on
 * both engines and leaves the app usable (docs/native-validation): the window stays open with the reason, the
 * failure is [ExitCategory.INSUFFICIENT_PROGRAM_MEMORY] on Pure Terry and Pure Kotlin, the window closes, another
 * program starts, and repeated failed launches do not keep memory.
 */
class GracefulFailureTest {
    private class Env(overlay: File, private val memMb: Int) : ShellEnv {
        override val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), overlay)
        override val stateStore = object : StateStore { var s: String? = null; override fun load() = s; override fun save(text: String) { s = text } }
        override fun runtimeFile(name: String): ByteArray? {
            val f = if (name == "catalog.json") File(SHARED, "program-manifests/catalog.json") else File(SHARED, "runtime/$name")
            return if (f.exists()) f.readBytes() else null
        }
        override val memoryLimitBytes: Int get() = memMb shl 20
    }

    private fun waitFor(sh: Shell, ms: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { sh.tick(); if (cond()) return true; Thread.sleep(20) }
        sh.tick(); return cond()
    }

    private fun usedHeapMb(): Long { repeat(3) { System.gc(); Thread.sleep(50) }; return Runtime.getRuntime().let { (it.totalMemory() - it.freeMemory()) shr 20 } }

    private fun check(engine: Int) {
        NativePrograms.catalog = NativeCatalog
        val dir = kotlin.io.path.createTempDirectory("graceful").toFile().apply { deleteOnExit() }
        val sh = Shell(Env(dir, 32)); sh.resize(800, 480); sh.tick()
        sh.settings.engine = engine
        val name = if (engine == Settings.ENGINE_NATIVE) "native" else "terry"
        var heapAfterFirst = 0L
        for (round in 1..4) {
            Launch.program(sh, "C:/Demo/Games/Talons.HC", null)
            val w = sh.windows.last { it.app is ProgramApp }
            val app = w.app as ProgramApp
            assertTrue("$name round $round: Talons ends", waitFor(sh, 120_000) { app.kernel.finished })
            assertEquals("$name round $round: ${app.kernel.exitMessage}", ExitCategory.INSUFFICIENT_PROGRAM_MEMORY, app.kernel.exitCategory)
            assertTrue("$name: the window stays open to show why", sh.windows.contains(w))
            assertTrue("$name: the reason is on the console", app.kernel.console.plainText().contains("out of memory", ignoreCase = true))
            repeat(5) { sh.tick() } // the shell keeps running
            sh.close(w, true)
            assertFalse("$name: the window closed", sh.windows.contains(w))
            if (round == 1) heapAfterFirst = usedHeapMb()
        }
        val heapAfterAll = usedHeapMb()
        assertTrue("$name: repeated failed launches keep memory (${heapAfterFirst} MB after one, $heapAfterAll MB after four)", heapAfterAll - heapAfterFirst < 24)
        // the app is still usable: another program starts and draws
        Launch.program(sh, "C:/Demo/Games/BomberGolf.HC", null)
        val bg = sh.windows.last { it.app is ProgramApp }.app as ProgramApp
        assertTrue("$name: BomberGolf runs after the failures", waitFor(sh, 30_000) { bg.kernel.frameCount > 10 && !bg.kernel.finished })
        sh.windows.toList().forEach { sh.close(it, true) }
        println("$name: INSUFFICIENT_PROGRAM_MEMORY x4, heap $heapAfterFirst -> $heapAfterAll MB, BomberGolf ran")
    }

    @Test fun talonsTooBigForTheMemoryClassFailsGracefullyOnPureTerry() = check(Settings.ENGINE_TERRY)

    @Test fun talonsTooBigForTheMemoryClassFailsGracefullyOnPureKotlin() = check(Settings.ENGINE_NATIVE)
}
