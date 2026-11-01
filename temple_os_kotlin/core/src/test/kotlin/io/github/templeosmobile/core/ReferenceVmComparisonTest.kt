package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File

/**
 * Runs the reference-VM harnesses (tools/reference-vm/harness/) on the app's interpreter (Pure Terry) and
 * saves what they print, for comparison with the original TempleOS's output (shared/test-vectors/reference-vm,
 * shared/test-vectors/dynexpr/cartesian-vm-results.json) by tools/reference-vm/compare_app.py.
 *
 * The harness files are the same files the VM runs; only the output routine differs (AppIO.HC instead of
 * VmIO.HC). Opt-in, because the Cartesian corpus compiles 3485 expressions and Talons needs 128 MiB:
 *
 *   ./gradlew :core:test --tests '*ReferenceVmComparisonTest*' -Dtempleos.vmcompare=OUTDIR
 *
 * The tests check only that each harness ran to its end; equality with the VM is reported by compare_app.py
 * (a mismatch with the original is a finding to describe, not something these tests may paper over).
 */
class ReferenceVmComparisonTest {
    private val outDir: File? = System.getProperty("templeos.vmcompare")?.let { File(it) }
    private val harnessDir = File(SHARED, "../tools/reference-vm/harness")

    private class HarnessEnv(fs: VirtualFs, private val memMb: Int) : TestEnv(fs) {
        override val memoryLimit: Int get() = memMb shl 20
    }

    private fun run(name: String, harness: List<String>, data: Map<String, File> = emptyMap(), memMb: Int = 32,
                    maxSeconds: Long = 1800, alsoNextToHarness: Boolean = false): String {
        Assume.assumeTrue("set -Dtempleos.vmcompare=OUTDIR to run", outDir != null)
        val overlay = java.nio.file.Files.createTempDirectory("vmcompare").toFile().also { it.deleteOnExit() }
        val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), overlay, quotaBytes = 512L shl 20)
        fs.mkdir("C:/Home/Harness")
        fs.mkdir("C:/Home/HData")
        val files = listOf("AppIO.HC") + harness
        for (f in files) fs.writeFile("C:/Home/Harness/$f", File(harnessDir, f).readBytes())
        for ((n, f) in data) {
            fs.writeFile("C:/Home/HData/$n", f.readBytes())
            if (alsoNextToHarness) fs.writeFile("C:/Home/Harness/$n", f.readBytes())
        }
        val main = files.joinToString("") { "#include \"C:/Home/Harness/$it\"\n" } + "HEnd;\n"
        val env = HarnessEnv(fs, memMb)
        val k = Kernel(env, "harness")
        k.virtualTime = true
        k.boot()
        val t0 = System.nanoTime()
        k.runProgram("C:/Home/Harness/Run.HC", main.toByteArray(Charsets.ISO_8859_1))
        while (System.nanoTime() - t0 < maxSeconds * 1_000_000_000L) {
            if (k.step(50_000_000) < 0) break
            if (fs.exists("C:/Home/HarnessOut.TXT")) break
        }
        val secs = (System.nanoTime() - t0) / 1e9
        val out = fs.readFile("C:/Home/HarnessOut.TXT")?.toString(Charsets.ISO_8859_1)
        val text = out ?: "HARNESS-INCOMPLETE after %.1f s; console tail:\n%s\n".format(secs, k.console.plainText().takeLast(4000))
        outDir!!.mkdirs()
        File(outDir, "$name.txt").writeText(text, Charsets.ISO_8859_1)
        File(outDir, "$name.meta.json").writeText(
            """{"harness": ${files.joinToString(",", "[", "]") { "\"$it\"" }}, "engine": "Pure Terry (JVM)", "seconds": ${"%.1f".format(secs)}, "mem_mib": $memMb, "virtual_time": true}""" + "\n")
        println("$name: ${if (out != null) "done" else "INCOMPLETE"} in %.1f s".format(secs))
        return text
    }

    @Test fun rng() {
        assertTrue(run("rng", listOf("Rng.HC")).contains("HARNESS-DONE"))
    }

    @Test fun evalOrder() {
        assertTrue(run("evalorder", listOf("EvalOrder.HC")).contains("HARNESS-DONE"))
    }

    @Test fun x87Probe() {
        assertTrue(run("x87probe", listOf("X87Probe.HC")).contains("HARNESS-DONE"))
    }

    @Test fun cartesian() {
        // the same flattened corpus the VM run reads (tools/reference-vm/fixtures.py cartesian-input)
        val vmInput = File(SHARED, "test-vectors/dynexpr/cartesian-vm-input.txt")
        assertTrue("run tools/reference-vm/fixtures.py cartesian-input first", vmInput.exists())
        assertTrue(run("cartesian", listOf("Cartesian.HC"), mapOf("cartesian.txt" to vmInput)).contains("HARNESS-DONE"))
    }

    @Test fun talons() {
        Assume.assumeTrue(outDir != null)
        // the instrumented copy the VM run uses: the bundled (= CD) Talons.HC without its auto-run line
        val orig = File(SHARED, "bundled-fs/Demo/Games/Talons.HC").readBytes()
        val s = String(orig, Charsets.ISO_8859_1)
        val i = s.indexOf("\nTalons;\n")
        assertTrue(i > 0 && s.indexOf("\nTalons;\n", i + 1) < 0)
        val copy = File(outDir, "TalonsNoRun.HC")
        copy.writeBytes((s.substring(0, i + 1) + s.substring(i + 9)).toByteArray(Charsets.ISO_8859_1))
        val mem = System.getProperty("templeos.vmcompare.talonsmb")?.toInt() ?: 256
        assertTrue(run("talons", listOf("Talons.HC"), mapOf("TalonsNoRun.HC" to copy), memMb = mem, alsoNextToHarness = true)
            .contains("HARNESS-DONE"))
    }

    @Test fun xcaliber() {
        assertTrue(run("xcaliber-templeos_rand", listOf("XCaliberPhysics.HC")).contains("HARNESS-DONE"))
    }

    @Test fun xcaliberHarnessLcg() {
        assertTrue(run("xcaliber-harness_lcg", listOf("XCaliberLcg.HC", "XCaliberPhysics.HC")).contains("HARNESS-DONE"))
    }
}
