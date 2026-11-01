package io.github.templeosmobile.purekotlin

import org.junit.Test
import java.io.File
import java.lang.management.ManagementFactory

/**
 * Pure Terry vs Pure Kotlin on the same host: the cost of simulating the same program, input and
 * virtual time. Both engines run exactly the same work (ticks, frames, sound) — the parity tests check
 * that — so the host time per simulated second is a like-for-like throughput measure.
 *
 *   -Dtempleos.bench=<path>[,<path>]|default   -Dtempleos.benchsecs=10  -Dtempleos.benchruns=5
 *
 * Runs alternate engines (T N T N ...) after one warm-up run each, so JIT warm-up and thermal drift
 * hit both. Results: build/bench-jvm.json (all runs) and a table on stdout.
 */
class BenchmarkTest {
    companion object {
        val DEFAULT = listOf(
            "C:/Demo/Games/BomberGolf.HC", "C:/Demo/Games/BattleLines.HC", "C:/Demo/Games/Varoom.HC", "C:/Demo/Games/Maze.HC",
            "C:/Apps/X-Caliber/Run.HC", "C:/Demo/Games/Squirt.HC", "C:/Demo/Graphics/Bounce.HC", "C:/Demo/Graphics/Life.HC",
            "C:/Demo/Games/RawHide.HC", "C:/Demo/Games/Talons.HC",
        )
    }

    private val cpu = ManagementFactory.getThreadMXBean()

    /** Host CPU time of every thread in this JVM (task threads included), ns. */
    private fun processCpuNs(): Long {
        val os = ManagementFactory.getOperatingSystemMXBean()
        return (os as? com.sun.management.OperatingSystemMXBean)?.processCpuTime ?: cpu.currentThreadCpuTime
    }

    class Sample(val engine: Engine, val wallMs: Double, val cpuMs: Double, val ticks: Long, val frames: Long, val gcMs: Long)

    private fun gcMs() = ManagementFactory.getGarbageCollectorMXBeans().sumOf { it.collectionTime }

    private fun once(path: String, engine: Engine, secs: Long): Sample {
        val s = Script.sweep(secs * 1000)
        System.gc()
        val g0 = gcMs(); val c0 = processCpuNs(); val t0 = System.nanoTime()
        val r = runScript(path, engine, s, light = true)
        val t1 = System.nanoTime(); val c1 = processCpuNs(); val g1 = gcMs()
        val last = r.checkpoints.last()
        r.kernel.terminate("done")
        return Sample(engine, (t1 - t0) / 1e6, (c1 - c0) / 1e6, last.ticks, last.frameCount, g1 - g0)
    }

    @Test
    fun benchmark() {
        val which = System.getProperty("templeos.bench") ?: return
        val paths = if (which == "default") DEFAULT else which.split(',')
        val secs = System.getProperty("templeos.benchsecs")?.toLong() ?: 10L
        val runs = System.getProperty("templeos.benchruns")?.toInt() ?: 5
        val rows = ArrayList<String>()
        val table = StringBuilder()
        table.append("%-34s %12s %12s %8s %10s %8s\n".format("program", "terry ms", "kotlin ms", "speedup", "ticks", "frames"))
        for (path in paths) {
            try {
                // profiling aid: -Dtempleos.benchonly=native|terry runs one engine only (as TEMPLEOS_BENCHONLY in Swift)
                System.getProperty("templeos.benchonly")?.let { only ->
                    val e = if (only == "native") Engine.NATIVE else Engine.TERRY
                    repeat(runs) { val s = once(path, e, secs); table.append("$path $only: %.1f ms wall, %.1f ms cpu, gc %d ms, ticks %d\n".format(s.wallMs, s.cpuMs, s.gcMs, s.ticks)) }
                    continue
                }
                once(path, Engine.TERRY, minOf(secs, 2)); once(path, Engine.NATIVE, minOf(secs, 2)) // warm-up
                val samples = ArrayList<Sample>()
                for (i in 0 until runs) {
                    val order = if (i % 2 == 0) listOf(Engine.TERRY, Engine.NATIVE) else listOf(Engine.NATIVE, Engine.TERRY)
                    for (e in order) samples.add(once(path, e, secs))
                }
                fun med(e: Engine, f: (Sample) -> Double) = samples.filter { it.engine == e }.map(f).sorted().let { it[it.size / 2] }
                val tw = med(Engine.TERRY) { it.wallMs }; val nw = med(Engine.NATIVE) { it.wallMs }
                val ticks = samples.first().ticks; val frames = samples.first().frames
                val same = samples.all { it.ticks == ticks && it.frames == frames }
                table.append("%-34s %12.1f %12.1f %7.2fx %10d %8d%s\n".format(path.removePrefix("C:/"), tw, nw, tw / nw, ticks, frames, if (same) "" else "  (work differed!)"))
                rows.add("    {\"path\": \"$path\", \"virtual_seconds\": $secs, \"runs\": $runs, \"same_work\": $same, \"ticks\": $ticks, \"frames\": $frames, " +
                    "\"terry_wall_ms_median\": %.1f, \"kotlin_wall_ms_median\": %.1f, \"speedup_wall\": %.3f, ".format(tw, nw, tw / nw) +
                    "\"terry_cpu_ms_median\": %.1f, \"kotlin_cpu_ms_median\": %.1f, \"speedup_cpu\": %.3f, ".format(med(Engine.TERRY) { it.cpuMs }, med(Engine.NATIVE) { it.cpuMs }, med(Engine.TERRY) { it.cpuMs } / med(Engine.NATIVE) { it.cpuMs }) +
                    "\"samples\": [" + samples.joinToString(", ") { "{\"engine\": \"${it.engine}\", \"wall_ms\": %.1f, \"cpu_ms\": %.1f, \"gc_ms\": %d}".format(it.wallMs, it.cpuMs, it.gcMs) } + "]}")
            } catch (e: Throwable) {
                table.append("%-34s failed: %s\n".format(path, e.toString().take(100)))
            }
        }
        val env = "\"host\": {\"os\": \"${System.getProperty("os.name")} ${System.getProperty("os.version")}\", \"arch\": \"${System.getProperty("os.arch")}\", " +
            "\"cpus\": ${Runtime.getRuntime().availableProcessors()}, \"jvm\": \"${System.getProperty("java.vm.name")} ${System.getProperty("java.version")}\"}"
        File("build").mkdirs()
        File("build/bench-jvm.json").writeText("{\n  $env,\n  \"programs\": [\n" + rows.joinToString(",\n") + "\n  ]\n}\n")
        println(table)
    }
}
