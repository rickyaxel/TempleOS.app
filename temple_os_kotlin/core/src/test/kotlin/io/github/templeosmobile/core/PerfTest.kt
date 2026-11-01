package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Catalog
import org.junit.Test
import java.io.File
import java.lang.management.ManagementFactory

/**
 * Real-clock program benchmarks (opt-in): -Dtempleos.perf=<catalog ids or path parts, comma
 * separated, or "all"> [-Dtempleos.perfsec=6] [-Dtempleos.perfout=build/perf-kotlin.json].
 *
 * Each program runs on this thread exactly as KernelRunner runs it in the app (step(12 ms), then
 * wait until the kernel next needs to run), with the input a player gives: an arrow key held with
 * the TempleOS typematic repeat, SPACE taps, and mouse moves and clicks. The first second (boot,
 * JIT warm-up) is not measured. Reported per program: frames composed per second, composition time
 * per frame (draw_it + ODEs + controls + publish: mean, p50, p95, max), kernel-thread CPU share,
 * VM instructions per second, frames published per second, speaker changes per second.
 * Same scenario as Swift PerfTests (shared/benchmark-scenarios/player-input.json documents it).
 */
class PerfTest {
    @Test
    fun perf() {
        val which = System.getProperty("templeos.perf") ?: return
        val seconds = System.getProperty("templeos.perfsec")?.toDoubleOrNull() ?: 6.0
        val root = File(SHARED, "bundled-fs")
        val cat = Catalog.parse(File(SHARED, "program-manifests/catalog.json").readText())
        val progs = cat.programs.filter { p -> which == "all" || which.split(",").any { p.id == it || p.path.contains(it) } }
        val rows = ArrayList<String>()
        val json = StringBuilder("[\n")
        val bean = ManagementFactory.getThreadMXBean()
        for (p in progs) {
            // programs that exit on a key (SPACE, arrows) are measured again with mouse input only
            var res = measure(p, root, seconds, bean, keys = true) ?: run { rows.add("%-26s CRASH".format(p.id)); continue }
            if (res["finished"] == true) res = measure(p, root, seconds, bean, keys = false) ?: res
            rows.add(res.entries.joinToString("  ") { "${it.key}=${it.value}" })
            json.append("  {").append(res.entries.joinToString(", ") { "\"${it.key}\": " + (if (it.value is String) "\"${it.value}\"" else it.value.toString()) }).append("},\n")
        }
        if (json.endsWith(",\n")) json.setLength(json.length - 2)
        json.append("\n]\n")
        val out = File(System.getProperty("templeos.perfout") ?: "build/perf-kotlin.json")
        out.parentFile?.mkdirs(); out.writeText(json.toString())
        println("PERF kotlin (JVM ${System.getProperty("java.version")}, ${seconds}s each):\n" + rows.joinToString("\n"))
    }

    private fun measure(p: io.github.templeosmobile.core.ui.ProgramInfo, root: File, seconds: Double,
                        bean: java.lang.management.ThreadMXBean, keys: Boolean): LinkedHashMap<String, Any>? {
        val fs = LayeredFs(DirBundle(root, File(SHARED, "bundled-fs.index")), java.nio.file.Files.createTempDirectory("perf").toFile())
        val env = object : TestEnv(fs) { var tones = 0L; override fun sound(kernel: Kernel, freq: Double, atNs: Long) { tones++ } }
        val k = Kernel(env, p.id)
        val b0 = System.nanoTime()
        k.boot()
        val bootMs = (System.nanoTime() - b0) / 1e6
        val f = File(root, p.path.removePrefix("C:/"))
        try { k.runProgram(p.path, f.readBytes()) } catch (e: Exception) { return null }
        val start = System.nanoTime()
        val warm = start + 1_000_000_000L
        val end = warm + (seconds * 1e9).toLong()
        var measuring = false
        var fr0 = 0L; var cpu0 = 0L; var in0 = 0L; var pub0 = 0L; var tone0 = 0L; var t0 = start
        var nextKey = start; var keyPhase = 0
        var heldSince = -1L; var lastRepeat = 0L
        var finished = false
        while (true) {
            val now = System.nanoTime()
            if (now >= end) break
            if (!measuring && now >= warm) {
                measuring = true; k.frameStats.reset()
                fr0 = k.frameCount; cpu0 = bean.currentThreadCpuTime; in0 = k.vm.instructionsExecuted
                pub0 = k.publishedVersion; tone0 = env.tones; t0 = now
            }
            // player input (wall-clock schedule, as touches arrive in the app)
            val ms = (now - start) / 1_000_000
            k.post(KInput.Mouse(170 + ((ms / 10) % 300).toInt(), 120 + ((ms / 7) % 240).toInt(), (ms / 500) % 4 == 1L, false))
            if (keys && now >= nextKey) {
                when (keyPhase % 4) {
                    0, 2 -> { val (ch, sc) = Keys.forChar(' '.code); k.post(KInput.Key(ch, sc, true)); k.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)) }
                    1 -> { val (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(KInput.Key(ch, sc, true)); heldSince = now; lastRepeat = now }
                    3 -> { val (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)); heldSince = -1 }
                }
                keyPhase++; nextKey = now + 700_000_000L
            }
            if (keys && heldSince >= 0 && now - heldSince >= 250_000_000L && now - lastRepeat >= 33_000_000L) {
                val (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(KInput.Key(ch, sc, true)); lastRepeat = now
            }
            val wait = try { k.step(12_000_000) } catch (e: Exception) { -1L }
            if (wait < 0) { finished = true; break }
            if (wait > 0) java.util.concurrent.locks.LockSupport.parkNanos(minOf(wait, 50_000_000L))
        }
        val wall = (System.nanoTime() - t0) / 1e9
        val st = k.frameStats
        val frames = k.frameCount - fr0
        val cpu = (bean.currentThreadCpuTime - cpu0) / 1e9
        val res = linkedMapOf<String, Any>(
            "id" to p.id, "input" to (if (keys) "keys" else "mouse"), "finished" to finished, "bootMs" to "%.0f".format(bootMs).toDouble(),
            "fps" to r1(frames / wall), "composeMeanMs" to r2(if (st.frames > 0) st.composeTotalNs / 1e6 / st.frames else 0.0),
            "composeP50Ms" to r2(st.composePercentile(50) / 1e6), "composeP95Ms" to r2(st.composePercentile(95) / 1e6),
            "composeMaxMs" to r2(st.composeMaxNs / 1e6), "cpuPct" to r1(100 * cpu / wall),
            "minstrPerSec" to r1((k.vm.instructionsExecuted - in0) / 1e6 / wall),
            "publishedPerSec" to r1((k.publishedVersion - pub0) / wall), "tonesPerSec" to r1((env.tones - tone0) / wall))
        k.terminate("done")
        return res
    }

    private fun r1(v: Double) = Math.round(v * 10) / 10.0
    private fun r2(v: Double) = Math.round(v * 100) / 100.0
}
