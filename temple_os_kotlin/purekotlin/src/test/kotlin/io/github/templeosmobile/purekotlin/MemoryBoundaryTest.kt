package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.bench.*
import org.junit.Test
import java.io.File

/**
 * Program-memory boundary sweep (docs/native-validation, Talons): runs a program on both engines at a
 * list of program-memory sizes and records whether it started, how it failed (the kernel's exit
 * message and failure category) and how much of the arena it used.
 *
 *   -Dtempleos.membounds=C:/Demo/Games/Talons.HC  -Dtempleos.membounds.mb=32,64,96,128  -Dtempleos.membounds.secs=4
 *   -Dtempleos.membounds.engines=terry,native
 *
 * Results: build/membounds.json and a table on stdout.
 */
class MemoryBoundaryTest {
    @Test
    fun sweep() {
        val path = System.getProperty("templeos.membounds") ?: return
        val sizes = (System.getProperty("templeos.membounds.mb") ?: "32,48,64,80,88,92,94,95,96,97,100,112,128,160,256").split(',').map { it.trim().toInt() }
        val secs = System.getProperty("templeos.membounds.secs")?.toLong() ?: 4L
        val rows = ArrayList<String>()
        val table = StringBuilder("%-7s %-7s %-8s %12s %12s %12s  %s\n".format("MiB", "engine", "result", "high water", "peak alloc", "arena", "exit"))
        val engines = (System.getProperty("templeos.membounds.engines") ?: "terry,native").split(',').map { if (it == "terry") Engine.TERRY else Engine.NATIVE }
        for (mb in sizes) for (engine in engines) {
            val o = ScenarioRunner.Options(light = true, memMb = mb, env = { fs -> ScenarioEnv(fs, mb, ::sharedRuntimeFile) })
            val res = try {
                val r = runner.run(path, engine.core, ScenarioScript.sweep(secs * 1000), o)
                val k = r.kernel
                val exit = k.exitMessage ?: ""
                val ok = !k.finished && r.failure == null
                val category = k.exitCategory ?: ""
                val consoleTail = k.console.plainText().takeLast(300)
                k.terminate("done")
                Triple(if (ok) "runs" else "ended", r.stats, "$category|$exit|$consoleTail")
            } catch (e: Throwable) { Triple("host-exception", null, e.toString()) }
            val (result, st, detail) = res
            table.append("%-7d %-7s %-8s %12d %12d %12d  %s\n".format(mb, engine.name.lowercase(), result, st?.arenaHighWater ?: -1, st?.arenaPeakAllocated ?: -1, st?.arenaBytes ?: -1,
                detail.replace('\n', ' ').take(140)))
            rows.add("    {\"memmb\": $mb, \"engine\": \"${engine.name.lowercase()}\", \"result\": \"$result\", \"arena_high_water\": ${st?.arenaHighWater ?: -1}, " +
                "\"arena_peak_allocated\": ${st?.arenaPeakAllocated ?: -1}, \"arena_bytes\": ${st?.arenaBytes ?: -1}, \"boot_ms\": ${st?.let { it.bootWallNs / 1e6 } ?: -1}, " +
                "\"detail\": \"" + detail.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"}")
        }
        File("build").mkdirs()
        File("build/membounds.json").writeText("{\n  \"program\": \"$path\", \"virtual_seconds\": $secs,\n  \"runs\": [\n" + rows.joinToString(",\n") + "\n  ]\n}\n")
        println(table)
    }
}
