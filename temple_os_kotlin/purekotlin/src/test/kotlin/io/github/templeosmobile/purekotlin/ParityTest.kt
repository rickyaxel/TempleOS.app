package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.core.ui.Catalog
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Differential tests: the same program, input and virtual clock on the interpreter (Pure Terry) and
 * on its Kotlin translation (Pure Kotlin); frames, palette, sound, console, budget ticks and every
 * global variable must agree at every checkpoint.
 *
 *   default                         BomberGolf
 *   -Dtempleos.parity=all           every translated catalog program (results: build/parity-results.json)
 *   -Dtempleos.parity=<path>[,...]  chosen programs
 *   -Dtempleos.paritysecs=4  -Dtempleos.paritysecsfor=<id>=<secs>[,...]  -Dtempleos.memmb=32
 */
class ParityTest {
    @Test
    fun bomberGolfSweep() {
        val s = Script.sweep(4000)
        val a = runScript("C:/Demo/Games/BomberGolf.HC", Engine.TERRY, s)
        val b = runScript("C:/Demo/Games/BomberGolf.HC", Engine.NATIVE, s)
        val d = compareRuns(a, b)
        File("build/parity").mkdirs()
        File("build/parity/game.bombergolf.terry.json").writeText(checkpointsJson(a.checkpoints))
        File("build/parity/game.bombergolf.native.json").writeText(checkpointsJson(b.checkpoints))
        a.kernel.terminate("done"); b.kernel.terminate("done")
        println("BomberGolf: terry frames=${a.checkpoints.last().frameCount} ticks=${a.checkpoints.last().ticks}; native frames=${b.checkpoints.last().frameCount} ticks=${b.checkpoints.last().ticks}")
        assertNull(d, d)
    }

    /** TreeCheckers completes its source from the board size chosen at start: every size, both engines. */
    @Test
    fun treeCheckersEveryBoardSize() {
        val path = "C:/Demo/Games/TreeCheckers.HC"
        val s = Script.sweep(1500)
        val fails = ArrayList<String>()
        for (size in 1L..9L) {
            val a = runScript(path, Engine.TERRY, s, popups = listOf(size))
            val b = runScript(path, Engine.NATIVE, s, popups = listOf(size))
            compareRuns(a, b)?.let { fails.add("size $size: $it") }
            if (a.kernel.finished) fails.add("size $size: the program ended (${a.kernel.exitMessage})")
            a.kernel.terminate("done"); b.kernel.terminate("done")
        }
        assertTrue(fails.joinToString("\n"), fails.isEmpty())
    }

    @Test
    fun sweepAll() {
        val which = System.getProperty("templeos.parity") ?: return
        NativePrograms.catalog = NativeCatalog
        val cat = Catalog.parse(File(SHARED, "program-manifests/catalog.json").readText())
        val paths = if (which == "all") cat.programs.map { it.path } else which.split(',')
        val ms = System.getProperty("templeos.paritysecs")?.toLong()?.times(1000) ?: 4000L
        val rows = ArrayList<String>()
        var pass = 0; var fail = 0; var skipped = 0
        for (path in paths) {
            val id = cat.programs.firstOrNull { it.path == path }?.id ?: path
            if (NativePrograms.find(path) == null) { rows.add(row(id, path, "not-translated", "", 0, 0)); skipped++; continue }
            // per-program durations (-Dtempleos.paritysecsfor=app.x-caliber=2,...): programs whose interpreted run is very slow
            val pms = System.getProperty("templeos.paritysecsfor")?.split(',')?.firstOrNull { it.substringBefore('=') == id }
                ?.substringAfter('=')?.toLong()?.times(1000) ?: ms
            val s = Script.sweep(pms)
            val t0 = System.nanoTime()
            val limit = System.getProperty("templeos.paritywall")?.toLong() ?: 120_000L
            val res = try {
                val a = runScript(path, Engine.TERRY, s, wallLimitMs = limit)
                val b = runScript(path, Engine.NATIVE, s, wallLimitMs = limit)
                val d = compareRuns(a, b)
                File("build/parity").mkdirs()
                File("build/parity/$id.terry.json").writeText(checkpointsJson(a.checkpoints))
                File("build/parity/$id.native.json").writeText(checkpointsJson(b.checkpoints))
                val fr = a.checkpoints.last().frameCount
                a.kernel.terminate("done"); b.kernel.terminate("done")
                Triple(d, fr, a.checkpoints.last().ticks)
            } catch (e: RunTimeout) { Triple("timeout: ${e.message}", 0L, 0L) } catch (e: Throwable) { Triple("exception: $e", 0L, 0L) }
            val (d, fr, ticks) = res
            if (d == null) pass++ else fail++
            rows.add(row(id, path, if (d == null) "parity" else if (d.startsWith("timeout")) "timeout" else "mismatch", d ?: "", fr, ticks))
            val line = "%-26s %-9s %5d frames %10d ticks  %5.1fs %s".format(id, if (d == null) "PARITY" else if (d.startsWith("timeout")) "TIMEOUT" else "MISMATCH", fr, ticks, (System.nanoTime() - t0) / 1e9, (d ?: "").take(160))
            println(line)
            File("build").mkdirs(); File("build/parity-progress.txt").appendText(line + "\n")
        }
        File("build").mkdirs()
        File("build/parity-results.json").writeText("{\n  \"duration_ms\": $ms,\n  \"pass\": $pass, \"fail\": $fail, \"not_translated\": $skipped,\n  \"programs\": [\n" + rows.joinToString(",\n") + "\n  ]\n}\n")
        println("parity: $pass pass, $fail mismatch, $skipped not translated")
    }

    private fun row(id: String, path: String, status: String, detail: String, frames: Long, ticks: Long): String =
        "    {\"id\": \"$id\", \"path\": \"$path\", \"status\": \"$status\", \"frames\": $frames, \"ticks\": $ticks, \"detail\": \"" +
            detail.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").take(400) + "\"}"
}

/** Debugging aid: the first task slice whose result or budget use differs between the engines. */
class SliceTraceTest {
    @Test
    fun bomberGolfSlices() {
        if (System.getProperty("templeos.slicetrace") == null) return
        val path = System.getProperty("templeos.slicetrace").ifEmpty { "C:/Demo/Games/BomberGolf.HC" }
        fun trace(e: Engine): List<String> {
            val out = ArrayList<String>()
            val (k, _) = bootProgram(path, e)
            k.sliceTrace = { t, r, d -> out.add("${k.now() / 1000}us ${t.name} r=$r ticks=$d") }
            val s = Script.sweep(4000)
            var i = 0
            var ms = 0L
            val evs = s.events
            while (ms <= s.durationMs) {
                while (i < evs.size && evs[i].ms <= ms) { val ev = evs[i]; when (ev) { is Ev.Key -> k.post(io.github.templeosmobile.core.kernel.KInput.Key(ev.ch, ev.sc, ev.down)); is Ev.Mouse -> k.post(io.github.templeosmobile.core.kernel.KInput.Mouse(ev.x, ev.y, ev.lb, ev.rb)); else -> {} }; i++ }
                if (!advanceTo(k, ms)) break
                ms += 20
            }
            k.terminate("done")
            return out
        }
        val a = trace(Engine.TERRY); val b = trace(Engine.NATIVE)
        // cross-platform: -Dtempleos.slicetracefile=<file> writes the interpreter's trace (the Swift test writes the same format)
        System.getProperty("templeos.slicetracefile")?.let { File(it).writeText(a.joinToString("\n") + "\n") }
        val i = (0 until minOf(a.size, b.size)).firstOrNull { a[it] != b[it] }
        if (i == null) { println("slices agree (${a.size})"); return }
        println("first differing slice #$i")
        for (j in maxOf(0, i - 5)..minOf(i + 5, a.size - 1)) println("  terry  ${a[j]}\n  native ${b.getOrNull(j)}")
    }
}
