package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Interpreter benchmarks (opt-in: -Dtempleos.bench=N runs each program N times).
 * Runs shared/test-vectors/bench/NAME.HC after boot and reports the best wall
 * time and the VM instruction rate. Same programs as Swift BenchTests.
 */
class BenchTest {
    @Test
    fun bench() {
        val reps = System.getProperty("templeos.bench")?.toIntOrNull() ?: return
        val files = File(SHARED, "test-vectors/bench").listFiles { f -> f.name.endsWith(".HC") }!!.sortedBy { it.name }
        val rows = ArrayList<String>()
        for (f in files) {
            var best = Long.MAX_VALUE; var instr = 0L; var out = ""
            repeat(reps) {
                val k = Kernel(TestEnv(), "bench")
                k.boot()
                val i0 = k.vm.instructionsExecuted
                val t0 = System.nanoTime()
                k.runProgram("C:/Home/${f.name}", f.readBytes())
                while (!k.finished) k.step(50_000_000)
                val dt = System.nanoTime() - t0
                if (dt < best) { best = dt; instr = k.vm.instructionsExecuted - i0 }
                out = k.console.plainText().trim().lines().last()
                assertNull("${f.name} failed: $out", k.exitMessage)
            }
            rows.add("%-12s %8.1f ms %12d instr %7.1f M instr/s  -> %s".format(f.name, best / 1e6, instr, instr * 1e3 / best, out))
        }
        println("BENCH kotlin (JVM ${System.getProperty("java.version")}):\n" + rows.joinToString("\n"))
    }
}
