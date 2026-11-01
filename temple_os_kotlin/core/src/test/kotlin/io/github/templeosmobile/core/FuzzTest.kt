package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Random
import java.util.concurrent.atomic.AtomicReference

/**
 * Bounded, fixed-seed fuzz/property tests for everything that consumes
 * untrusted-ish input. A "defect" is any host-level failure: a JVM exception
 * other than a HolyC compile error / HolyC exception / FsError escaping the
 * API, a caught-but-internal host error reported by the kernel, or a hang.
 *
 * Iterations: per-target defaults keep each test well under a minute; override
 * with -Dtempleos.fuzz.iters=N (or env TEMPLEOS_FUZZ_ITERS). Seed base:
 * -Dtempleos.fuzz.seed / TEMPLEOS_FUZZ_SEED. Minimized reproducers are written
 * to shared/test-vectors/fuzz-repro/ and the test fails.
 */
class FuzzTest {
    companion object {
        private fun prop(p: String, e: String): String? = System.getProperty(p) ?: System.getenv(e)
        val ITERS: Int? = prop("templeos.fuzz.iters", "TEMPLEOS_FUZZ_ITERS")?.toIntOrNull()
        val SEED: Long = prop("templeos.fuzz.seed", "TEMPLEOS_FUZZ_SEED")?.toLongOrNull() ?: 0x7E3B1E05L
        val REPRO = File(SHARED, "test-vectors/fuzz-repro")
        fun iters(default: Int) = ITERS ?: default
        /** Everything the fuzzer prints is also appended here (test-results XML can be replaced by concurrent builds). */
        val LOG = File(prop("templeos.fuzz.log", "TEMPLEOS_FUZZ_LOG") ?: (System.getProperty("java.io.tmpdir") + "/templeos-fuzz-kotlin.log"))
        @Synchronized fun log(s: String) { println(s); try { LOG.appendText(s + "\n") } catch (_: Exception) {} }
        fun caseSeed(target: String, i: Int): Long = SEED * 1_000_003L + target.hashCode().toLong() * 7919L + i

        /** Shell headless environment with a temp overlay (from ShellUiTest.kt). */
        fun tmpDir(prefix: String): File = Files.createTempDirectory(prefix).toFile()

        val corpusHC: List<Pair<String, ByteArray>> by lazy {
            val files = ArrayList<File>()
            File(SHARED, "test-vectors/holyc").listFiles()?.filter { it.name.endsWith(".HC") }?.let { files.addAll(it) }
            for (d in listOf("bundled-fs/Demo", "bundled-fs/Demo/Games", "bundled-fs/Home/Examples", "bundled-fs/Demo/Graphics"))
                File(SHARED, d).listFiles()?.filter { it.isFile && it.name.endsWith(".HC") && it.length() < 40_000 }?.let { files.addAll(it) }
            files.sortedBy { it.path }.map { it.path.substringAfter("shared/") to it.readBytes() }
        }
        val corpusDD: List<Pair<String, ByteArray>> by lazy {
            (File(SHARED, "bundled-fs/Doc").listFiles() ?: emptyArray()).filter { it.name.endsWith(".DD") }.sortedBy { it.name }
                .map { it.name to it.readBytes() }
        }
    }

    // ================================================================ harness

    private var leakedThreads = 0

    class Defect(val target: String, val seed: Long, val sig: String, val detail: String, var input: ByteArray)

    /** Runs [block] on a fresh thread (JVM default stack, like the app's kernel thread) with a wall-clock limit. */
    private fun isolated(timeoutMs: Long, onTimeout: () -> Unit = {}, block: () -> String?): Pair<String?, String> {
        val res = AtomicReference<Pair<String?, String>>(null)
        val th = Thread(null, {
            res.set(try { block() to "" } catch (t: Throwable) { sigOf(t) to stackOf(t) })
        }, "fuzz", 0)
        th.isDaemon = true
        th.start()
        th.join(timeoutMs)
        if (th.isAlive) {
            val st = th.stackTrace
            val where = st.firstOrNull { it.className.startsWith("io.github.templeosmobile.core") && !it.className.contains("FuzzTest") }
                ?.let { "${it.fileName}:${it.methodName}" } ?: "?"
            val trace = st.take(16).joinToString("\n") { "  at $it" }
            onTimeout()
            th.join(3000)
            if (th.isAlive) { leakedThreads++; return "HANG(unresponsive)@$where" to trace }
            // Stoppable but slower than the wall limit: the documented limitation V-17 (natives
            // that call HolyC per point). Logged, not a defect; unresponsive hangs still are.
            println("[fuzz] slow but stopped by interrupt @$where")
            return null to trace
        }
        return res.get() ?: ("HANG(no result)" to "")
    }

    private fun threadStack(th: Thread) = th.stackTrace.take(12).joinToString("\n") { "  at $it" }
    private fun topFrame(t: Throwable): String =
        t.stackTrace.firstOrNull { it.className.startsWith("io.github.templeosmobile.core") && !it.className.contains("FuzzTest") }
            ?.let { "${it.fileName}:${it.lineNumber}" } ?: (t.stackTrace.firstOrNull()?.let { "${it.fileName}:${it.lineNumber}" } ?: "?")
    private fun sigOf(t: Throwable): String {
        if (t is StackOverflowError) {
            // the recursion site: the most repeated frame of the (truncated) trace
            val f = t.stackTrace.filter { it.className.startsWith("io.github.templeosmobile.core") }
                .groupingBy { "${it.fileName}:${it.methodName}" }.eachCount().maxByOrNull { it.value }?.key ?: topFrame(t)
            return "StackOverflowError@recursion:$f"
        }
        return "${t.javaClass.simpleName}@${topFrame(t)}"
    }
    private fun stackOf(t: Throwable) = (listOf(t.toString().take(300)) + t.stackTrace.take(14).map { "  at $it" }).joinToString("\n")

    /** Classic ddmin over chunks of [input] (bytes or lines) keeping [sig] reproducible. */
    private fun minimize(input: ByteArray, sig: String, budgetMs: Long, exec: (ByteArray) -> String?): ByteArray {
        val deadline = System.currentTimeMillis() + budgetMs
        fun same(b: ByteArray) = System.currentTimeMillis() < deadline && exec(b) == sig
        // pass 1: lines
        var units: List<ByteArray> = splitLines(input)
        var n = 2
        while (units.size >= 2 && System.currentTimeMillis() < deadline) {
            val chunk = (units.size + n - 1) / n
            var reduced = false
            var i = 0
            while (i < units.size) {
                val cand = units.subList(0, i) + units.subList(minOf(units.size, i + chunk), units.size)
                if (cand.isNotEmpty() && same(join(cand))) { units = cand; n = maxOf(n - 1, 2); reduced = true; break }
                i += chunk
            }
            if (!reduced) { if (n >= units.size) break; n = minOf(units.size, n * 2) }
        }
        // pass 2: bytes (bounded)
        var b = join(units)
        n = 2
        while (b.size >= 2 && System.currentTimeMillis() < deadline) {
            val chunk = (b.size + n - 1) / n
            var reduced = false
            var i = 0
            while (i < b.size) {
                val cand = b.copyOfRange(0, i) + b.copyOfRange(minOf(b.size, i + chunk), b.size)
                if (cand.isNotEmpty() && same(cand)) { b = cand; n = maxOf(n - 1, 2); reduced = true; break }
                i += chunk
            }
            if (!reduced) { if (n >= b.size) break; n = minOf(b.size, n * 2) }
        }
        return b
    }

    private fun splitLines(b: ByteArray): List<ByteArray> {
        val res = ArrayList<ByteArray>(); var s = 0
        for (i in b.indices) if (b[i] == '\n'.code.toByte()) { res.add(b.copyOfRange(s, i + 1)); s = i + 1 }
        if (s < b.size) res.add(b.copyOfRange(s, b.size))
        return res
    }
    private fun join(l: List<ByteArray>): ByteArray { val o = java.io.ByteArrayOutputStream(); l.forEach { o.write(it) }; return o.toByteArray() }

    private fun printable(b: ByteArray, max: Int = 600): String {
        val sb = StringBuilder()
        for (x in b.take(max)) { val c = x.toInt() and 0xFF; if (c in 32..126 || c == 10) sb.append(c.toChar()) else sb.append("\\x%02x".format(c)) }
        if (b.size > max) sb.append("...(${b.size} bytes)")
        return sb.toString()
    }

    /** Records a defect (deduplicated by signature), minimizing and saving a reproducer. */
    private inner class Collector(val target: String, val ext: String = "bin") {
        val defects = LinkedHashMap<String, Defect>()
        var ran = 0
        /** Total minimization time for this target (keeps a defect-rich run bounded). */
        var minimizeLeftMs = 40_000L
        /** Unresponsive hung threads cannot be killed and keep burning CPU: stop the target after a few. */
        val tooManyLeaks get() = leakedThreads >= 2
        fun found(seed: Long, sig: String, detail: String, input: ByteArray, exec: ((ByteArray) -> String?)?, minimizeBudgetMs: Long = 20_000) {
            if (sig.startsWith("HANG(slow")) { log("[fuzz:$target] note seed=$seed $sig (interrupt worked; not counted as a defect)"); return }
            if (defects.containsKey(sig)) return
            val d = Defect(target, seed, sig, detail, input)
            defects[sig] = d
            log("[fuzz:$target] DEFECT seed=$seed sig=$sig\n$detail")
            if (exec != null && !sig.startsWith("HANG") && minimizeLeftMs > 0) {
                val t0 = System.currentTimeMillis()
                val m = minimize(input, sig, minOf(minimizeBudgetMs, minimizeLeftMs), exec)
                minimizeLeftMs -= System.currentTimeMillis() - t0
                if (exec(m) == sig) d.input = m
            }
            REPRO.mkdirs()
            val base = "kotlin-$target-" + sig.replace(Regex("[^A-Za-z0-9_.-]"), "_").take(80)
            File(REPRO, "$base.$ext").writeBytes(d.input)
            File(REPRO, "$base.txt").writeText("runtime: kotlin\ntarget: $target\nseed: $seed\nsignature: $sig\nminimized input (${d.input.size} bytes): ${printable(d.input, 2000)}\n\n$detail\n")
            log("[fuzz:$target] minimized (${d.input.size} bytes): ${printable(d.input)}")
        }
        fun finish(iters: Int) {
            log("[fuzz:$target] ${if (ran > 0) ran else iters} iterations run, ${defects.size} distinct defect(s)")
            if (defects.isNotEmpty()) log("[fuzz:$target] FAIL: " + defects.values.joinToString("; ") { "seed=${it.seed} ${it.sig}" })
            if (defects.isNotEmpty())
                fail("[fuzz:$target] ${defects.size} defect(s):\n" + defects.values.joinToString("\n") { "seed=${it.seed} ${it.sig} input=${printable(it.input, 200)}" })
        }
    }

    // ================================================================ HolyC execution

    /**
     * Boots a fresh kernel, compiles and runs [src] in virtual time for a bounded
     * number of steps. Returns null when everything stayed at the HolyC level.
     */
    private fun runProgramCase(src: ByteArray, maxSteps: Int = 60, wallMs: Long = 8000, flagStkOver: Boolean = false,
                               fs: VirtualFs? = null, setup: (Kernel) -> Unit = {}): Pair<String?, String> {
        val kref = AtomicReference<Kernel>()
        val det = AtomicReference("")
        val r = isolated(wallMs, onTimeout = { kref.get()?.let { it.stopRequested = true; it.vm.interrupt = true } }) {
            val k = Kernel(TestEnv(fs), "fuzz")
            k.virtualTime = true
            k.boot()
            kref.set(k)
            setup(k)
            try { k.runProgram("C:/Home/Fuzz.HC", src) } catch (e: Throwable) { det.set(stackOf(e)); return@isolated "runProgram:" + sigOf(e) }
            var steps = 0
            while (steps++ < maxSteps) {
                val r = try { k.step(20_000_000) } catch (e: Throwable) { det.set(stackOf(e)); return@isolated "step:" + sigOf(e) }
                if (r < 0) break
            }
            val txt = k.console.plainText()
            det.set("console tail: " + txt.takeLast(400))
            Regex("internal error: ([A-Za-z.]+)").find(txt)?.let { return@isolated "kernel-internal-error:" + it.groupValues[1].substringAfterLast('.') }
            if (txt.contains("host stack overflow")) return@isolated "kernel-host-stack-overflow"
            if (flagStkOver && txt.contains("operand stack overflow")) return@isolated "masked-AIOOBE(operand stack overflow)"
            null
        }
        return r.first to (r.second.ifEmpty { det.get() })
    }

    // ================================================================ 1. lexer/preprocessor/parser/codegen

    private val specials: List<(Random) -> String> = listOf(
        { r -> "(".repeat(r.nextInt(20000) + 100) },
        { r -> "{".repeat(r.nextInt(20000) + 100) },
        { r -> "[".repeat(r.nextInt(5000) + 100) },
        { r -> "-".repeat(r.nextInt(20000) + 100) + "1" },
        { r -> "!".repeat(r.nextInt(20000) + 100) + "1" },
        { r -> "*".repeat(r.nextInt(20000) + 100) + "p" },
        { r -> "if(1)".repeat(r.nextInt(10000) + 100) + ";" },
        { r -> "x=".repeat(r.nextInt(10000) + 100) + "1;" },
        { r -> "1" + "+1".repeat(r.nextInt(30000) + 100) + ";" },
        { r -> "(I64)".repeat(r.nextInt(10000) + 100) + "1;" },
        { r -> "class A" + r.nextInt(99) + "{" + "union{".repeat(r.nextInt(3000) + 10) },
        { r -> "9".repeat(r.nextInt(400) + 20) },
        { r -> "0x" + "F".repeat(r.nextInt(100) + 17) },
        { r -> "1e" + r.nextInt(1000000) },
        { r -> "1." + "9".repeat(r.nextInt(400)) + "e-99999" },
        { _ -> "\"unterminated string" },
        { _ -> "/* unterminated comment" },
        { _ -> "/*/*/*" },
        { r -> "'" + "abcdefghijk".take(r.nextInt(11)) },
        { r -> "'" + "abcdefghijklmnop".take(r.nextInt(16) + 1) + "'" },
        { _ -> "\"\\" },
        { _ -> "\"\\x" },
        { _ -> "'\\" },
        { _ -> "\n#define A A\nA;\n" },
        { _ -> "\n#define A B\n#define B A\nA;\n" },
        { r -> val n = r.nextInt(24) + 4; "\n" + (0 until n).joinToString("") { "#define M$it M${it + 1} M${it + 1}\n" } + "M0;\n" },
        { _ -> "\n#include \"Fuzz.HC\"\n" },
        { _ -> "\n#include \"C:/Home/Fuzz.HC\"\n" },
        { _ -> "\n#include \"::/Home/Fuzz\"\n" },
        { _ -> "\n#include \"/etc/passwd\"\n" },
        { _ -> "\n#include \"../../../../../../etc/passwd\"\n" },
        { r -> "\n#if " + "(".repeat(r.nextInt(20000) + 10) + "1\n#endif\n" },
        { r -> "\n" + "#if 1\n".repeat(r.nextInt(5000) + 10) },
        { _ -> "\n#else\n" }, { _ -> "\n#endif\n" }, { _ -> "\n#\n" }, { _ -> "\n#define\n" }, { _ -> "\n#exe {}\n" },
        { r -> val sb = StringBuilder(); repeat(r.nextInt(6) + 1) { sb.append((5 + r.nextInt(27)).toChar()) }; sb.toString() },
        { r -> val sb = StringBuilder(); repeat(r.nextInt(6) + 1) { sb.append((0x80 + r.nextInt(128)).toChar()) }; sb.toString() },
        { _ -> "\u0000" },
        { r -> "\u0000" + String(CharArray(16) { (r.nextInt(256)).toChar() }) },
        { _ -> "\$\$" }, { _ -> "\$SP,\"\",BI=1\$" }, { _ -> "\$IB,\"\",BI=99\$" }, { _ -> "\$" },
        { _ -> "goto L;" }, { _ -> "L:" }, { _ -> "case 1:" }, { _ -> "break;" }, { _ -> "return;" },
        { _ -> "sizeof(" }, { _ -> "offset(" }, { _ -> "lastclass" }, { _ -> "->" }, { _ -> "::" },
        { _ -> "switch(1){start:end:}" }, { _ -> "try{throw;}catch{}" }, { _ -> "asm{" }, { _ -> "_extern" }, { _ -> "#exe{" },
        { _ -> "U0 F(...){F(1,2,3);}F;" }, { _ -> "I64 a[0x7FFFFFFF];" }, { _ -> "I64 a[-1];" }, { _ -> "U8 a[1<<40];" },
        { _ -> "class C{C c;};" }, { _ -> "class D{I64 x;} d; d.y;" }, { _ -> "U0 (*fp)()=0x1234; fp();" },
    )

    private fun mutateSource(r: Random, src0: ByteArray): ByteArray {
        var b = src0
        val rounds = 1 + r.nextInt(4)
        repeat(rounds) {
            when (r.nextInt(8)) {
                0 -> { b = b.copyOf(); repeat(1 + r.nextInt(8)) { if (b.isNotEmpty()) b[r.nextInt(b.size)] = r.nextInt(256).toByte() } }
                1 -> { b = b.copyOf(); repeat(1 + r.nextInt(8)) { if (b.isNotEmpty()) { val i = r.nextInt(b.size); b[i] = (b[i].toInt() xor (1 shl r.nextInt(8))).toByte() } } }
                2 -> if (b.isNotEmpty()) b = b.copyOfRange(0, r.nextInt(b.size))
                3, 4 -> { // token deletion / duplication / swap
                    val toks = Regex("[A-Za-z_0-9]+|\\s+|.", RegexOption.DOT_MATCHES_ALL).findAll(String(b, Charsets.ISO_8859_1)).map { it.value }.toMutableList()
                    if (toks.isNotEmpty()) repeat(1 + r.nextInt(6)) {
                        val i = r.nextInt(toks.size)
                        when (r.nextInt(3)) {
                            0 -> if (toks.size > 1) toks.removeAt(i)
                            1 -> toks.add(i, toks[r.nextInt(toks.size)])
                            else -> { val j = r.nextInt(toks.size); val t = toks[i]; toks[i] = toks[j]; toks[j] = t }
                        }
                    }
                    b = toks.joinToString("").toByteArray(Charsets.ISO_8859_1)
                }
                5, 6 -> { val s = specials[r.nextInt(specials.size)](r).toByteArray(Charsets.ISO_8859_1); val i = if (b.isEmpty()) 0 else r.nextInt(b.size + 1); b = b.copyOfRange(0, i) + s + b.copyOfRange(i, b.size) }
                else -> { // splice from another file
                    val o = corpusHC[r.nextInt(corpusHC.size)].second
                    if (o.isNotEmpty()) { val a = r.nextInt(o.size); val e = minOf(o.size, a + r.nextInt(400)); val i = r.nextInt(b.size + 1); b = b.copyOfRange(0, i) + o.copyOfRange(a, e) + b.copyOfRange(i, b.size) }
                }
            }
        }
        return b
    }

    /** Compile-only: a lexer+parser+codegen pass over [src] on [k]'s program. Non-CompileError throwables are defects. */
    private fun compileOnly(k: Kernel, src: ByteArray, provider: SourceProvider?): String? {
        return try {
            val s = k.prog.session(SourceFile.parse("C:/Home/Fuzz.HC", src), "C:/Home", provider, HashMap(k.defines))
            var n = 0
            while (s.next() != null && n++ < 100_000) {}
            null
        } catch (e: CompileError) { null }
        catch (e: VmFault) { null } catch (e: VmUncaught) { null } catch (e: VmKill) { null }
        catch (e: Throwable) { "compile:" + sigOf(e) }
    }

    @Test fun compilerFuzz() {
        val n = iters(1500)
        val c = Collector("compiler", "HC")
        var k: Kernel? = null
        var used = 0
        val self = AtomicReference(ByteArray(0))
        val provider = SourceProvider { p -> if (p.endsWith("Fuzz.HC", true) || p.endsWith("Fuzz.HC.HC", true) || p.endsWith("/Fuzz", true)) self.get() else null }
        val freshExec: (ByteArray) -> String? = { b ->
            self.set(b)
            isolated(15_000) { val kk = Kernel(TestEnv(), "fz").also { it.boot() }; compileOnly(kk, b, provider) }.first
        }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("compiler", i)
            val r = Random(seed)
            val (_, base) = corpusHC[r.nextInt(corpusHC.size)]
            val input = mutateSource(r, base)
            self.set(input)
            if (k == null || used++ > 40) { k = Kernel(TestEnv(), "fz").also { it.boot() }; used = 0 }
            val kk = k
            val (sig, detail) = isolated(15_000, onTimeout = { kk.vm.interrupt = true }) { compileOnly(kk, input, provider) }
            if (sig != null) {
                k = null // state may be poisoned
                // confirm on a fresh kernel (shared-kernel state can cause spurious failures)
                val confirm = freshExec(input)
                if (confirm != null) c.found(seed, confirm, detail, input, if (confirm.startsWith("HANG")) null else freshExec, 25_000)
                else log("[fuzz:compiler] seed=$seed $sig not reproducible on a fresh kernel (shared-state effect)")
            }
        }
        c.finish(n)
    }

    @Test fun compileAndRunFuzz() {
        val n = iters(150)
        val c = Collector("compile-run", "HC")
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("compile-run", i)
            val r = Random(seed)
            val (_, base) = corpusHC[r.nextInt(corpusHC.size)]
            val input = if (i % 5 == 0) base else mutateSource(r, base)
            val exec: (ByteArray) -> String? = { b -> runProgramCase(b, maxSteps = 40, wallMs = 10_000).first }
            val (sig, detail) = runProgramCase(input, maxSteps = 40, wallMs = 10_000)
            if (sig != null) c.found(seed, sig, detail, input, if (sig.startsWith("HANG")) null else exec, 30_000)
        }
        c.finish(n)
    }

    /** Fixed, targeted nesting/expansion probes: report the depth at which the host fails. */
    @Test fun deepNestingProbes() {
        val c = Collector("nesting", "HC")
        val probes = listOf(
            "parens" to { d: Int -> "I64 x=" + "(".repeat(d) + "1" + ")".repeat(d) + ";\n" },
            "braces" to { d: Int -> "{".repeat(d) + "}".repeat(d) + "\n" },
            "unary-minus" to { d: Int -> "I64 x=" + "-".repeat(d) + "1;\n" },
            "if-chain" to { d: Int -> "if(1)".repeat(d) + ";\n" },
            "assign-chain" to { d: Int -> "I64 x;" + "x=".repeat(d) + "1;\n" },
            "binary-chain" to { d: Int -> "I64 x=1" + "+1".repeat(d) + ";\n" },
            "casts" to { d: Int -> "I64 x=" + "(I64)".repeat(d) + "1;\n" },
            "if-directive" to { d: Int -> "#if " + "(".repeat(d) + "1" + ")".repeat(d) + "\n#endif\n" },
            "else-if" to { d: Int -> "I64 x=0;" + "if(x)x=1;else ".repeat(d) + "x=2;\n" },
            "nested-unions" to { d: Int -> "class A{" + "union{".repeat(d) + "I64 a;" + "};".repeat(d) + "};\n" },
            "macro-doubling" to { d: Int -> (0 until minOf(d, 40)).joinToString("") { "#define M$it M${it + 1} M${it + 1}\n" } + "#define M${minOf(d, 40)} 1\nI64 x=M0;\n" },
            "deref" to { d: Int -> "I64 *p=0; I64 x=" + "*".repeat(d) + "p;\n" },
            "index" to { d: Int -> "I64 x=a" + "[0]".repeat(d) + ";\n" },
            "call-args" to { d: Int -> "I64 x=Abs(" + "Abs(".repeat(d) + "1" + ")".repeat(d + 1) + ";\n" },
        )
        for ((name, gen) in probes) {
            val depths = if (name == "macro-doubling") listOf(10, 16, 20, 24, 28) else listOf(100, 1000, 3000, 10_000, 30_000, 100_000)
            for (d in depths) {
                val src = gen(d).toByteArray(Charsets.ISO_8859_1)
                val (sig, detail) = runProgramCase(src, maxSteps = 20, wallMs = 20_000)
                log("[fuzz:nesting] $name depth=$d -> ${sig ?: "ok"}")
                if (sig != null) {
                    // report the smallest failing depth (the probe ladder is the minimizer)
                    c.found(d.toLong(), "$name:$sig", "probe=$name depth=$d\n$detail", src, null)
                    break
                }
            }
        }
        c.finish(probes.size)
    }

    // ================================================================ 2. VM: random small programs, native calls

    private val interesting = longArrayOf(0, 1, -1, 2, 7, 8, 15, 16, 31, 63, 64, 255, 256, 4095, 4096, 65535, 0x10000, 0x7FFF, 0x8000,
        0x7FFFFFFF, 0x80000000L, 0xFFFFFFFFL, 0x100000000L, 0x40000000, 0x40000001, 0x20000000, 0x20000001, 0x3FFFFFFF, 0x1FFFFFFF,
        0x100000010L, 0x180000000L, Long.MAX_VALUE, Long.MIN_VALUE, Long.MIN_VALUE + 1, -0x80000000L, -2, -8, -16, -4096)

    private fun lit(v: Long) = if (v == Long.MIN_VALUE) "(1<<63)" else if (v < 0) "($v)" else "0x" + java.lang.Long.toHexString(v)

    private fun randInt(r: Random): String = when (r.nextInt(5)) {
        0, 1 -> lit(interesting[r.nextInt(interesting.size)])
        2 -> lit(r.nextInt(600).toLong() - 50)
        3 -> lit(r.nextLong())
        else -> lit(interesting[r.nextInt(interesting.size)] + r.nextInt(9) - 4)
    }

    private fun randPtr(r: Random): String = when (r.nextInt(10)) {
        0 -> "b0"; 1 -> "b1"; 2 -> "b0+" + r.nextInt(300); 3 -> "b1+" + r.nextInt(4200)
        4 -> "s0"; 5 -> "NULL"; 6 -> randInt(r); 7 -> "Fs"; 8 -> "b0+" + randInt(r)
        else -> "(b1+4096-" + r.nextInt(16) + ")"
    }

    private val fmtPieces = listOf("%d", "%s", "%c", "%X", "%p", "%f", "%e", "%g", "%n", "%z", "%Z", "%999999d",
        "%.999999f", "%,d", "%$", "%", "%t", "%P", "%q", "%Q", "%b", "%D", "%T", "%h25c", "%h-1c", "%07.3f", "%lld", "\\n", "\$", "\$\$", "\$FG,99\$",
        "\$RED\$", "\$\$FG\$\$", "%10000000s", "%-10000000d", "%.-5f")

    private fun randFmt(r: Random): String = "\"" + (0 until r.nextInt(5) + 1).joinToString("") { if (r.nextBoolean()) fmtPieces[r.nextInt(fmtPieces.size)] else "ab" } + "\""

    private fun randStmt(r: Random): String = when (r.nextInt(26)) {
        0 -> "MemCpy(${randPtr(r)},${randPtr(r)},${randInt(r)});"
        1 -> "MemSet(${randPtr(r)},${randInt(r)},${randInt(r)});"
        2 -> "MemSetU16(${randPtr(r)},${randInt(r)},${randInt(r)});"
        3 -> "MemSetU32(${randPtr(r)},${randInt(r)},${randInt(r)});"
        4 -> "MemSetI64(${randPtr(r)},${randInt(r)},${randInt(r)});"
        5 -> "x=MemCmp(${randPtr(r)},${randPtr(r)},${randInt(r)});"
        6 -> "x=b0[${randInt(r)}];"
        7 -> "b1[${randInt(r)}]=${randInt(r)};"
        8 -> "q=b1(I64*); q[${randInt(r)}]=${randInt(r)};"
        9 -> "x=*(${randPtr(r)})(I64*);"
        10 -> "*(${randPtr(r)})(U16*)=${randInt(r)};"
        11 -> "d=${randInt(r)}(F64); x=d; x=ToI64(d*${randInt(r)});"
        12 -> "x=(${randInt(r)})(U8)+(${randInt(r)})(I32)+(${randInt(r)})(U16)/(${randInt(r)}|1);"
        13 -> "x=${randInt(r)}%${randInt(r)}; x=${randInt(r)}/${randInt(r)};"
        14 -> "x=StrLen(${randPtr(r)});"
        15 -> "StrCpy(${randPtr(r)},${randPtr(r)});"
        16 -> "x=Str2I64(${randPtr(r)},${randInt(r)});"
        17 -> "Print(${randFmt(r)},${randInt(r)},${randPtr(r)},${randInt(r)});"
        18 -> "p=StrPrint(${randPtr(r)},${randFmt(r)},${randInt(r)},${randPtr(r)});"
        19 -> "p=MStrPrint(${randFmt(r)},${randInt(r)},${randPtr(r)},${randInt(r)});"
        20 -> "Free(${randPtr(r)});"
        21 -> "x=MSize(${randPtr(r)});"
        22 -> "p=MAlloc(${randInt(r)});"
        23 -> "x=Bt(${randPtr(r)},${randInt(r)}); Bts(${randPtr(r)},${randInt(r)});"
        24 -> "x=BFieldExtU32(${randPtr(r)},${randInt(r)},${randInt(r)});"
        else -> "x=${randInt(r)}<<${randInt(r)}; x=${randInt(r)}>>${randInt(r)}; x=(${randInt(r)})(U64)>>${randInt(r)};"
    }

    private fun vmProgram(r: Random, nStmts: Int, stmt: (Random) -> String): String {
        val sb = StringBuilder()
        sb.append("U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0=\"hello world\",*p; I64 *q,x,i; F64 d;\n")
        sb.append("for(i=0;i<256;i++) b0[i]=(i*${r.nextInt(255) + 1}+${r.nextInt(256)})&255;\n")
        sb.append("for(i=0;i<4096;i++) b1[i]=(i*${r.nextInt(255) + 1})&127;\n")
        if (r.nextBoolean()) sb.append("b0[${r.nextInt(256)}]=0; b1[${r.nextInt(4096)}]=0;\n")
        repeat(nStmts) { sb.append("try{").append(stmt(r)).append("}catch{Fs->catch_except=TRUE;}\n") }
        sb.append("\"FUZZDONE\\n\";\n")
        return sb.toString()
    }

    @Test fun vmRandomProgramsFuzz() {
        val n = iters(200)
        val c = Collector("vm", "HC")
        val exec: (ByteArray) -> String? = { b -> runProgramCase(b, maxSteps = 60, wallMs = 10_000, flagStkOver = true).first }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("vm", i)
            val r = Random(seed)
            val src = vmProgram(r, 30, ::randStmt).toByteArray(Charsets.ISO_8859_1)
            val (sig, detail) = runProgramCase(src, maxSteps = 60, wallMs = 10_000, flagStkOver = true)
            if (sig != null) c.found(seed, sig, detail, src, if (sig.startsWith("HANG")) null else exec, 40_000)
        }
        c.finish(n)
    }

    /** Native declarations from the runtime (name, parameter list) for the native-call fuzzer. */
    private val natives: List<Pair<String, List<String>>> by lazy {
        val txt = listOf("Prelude.HC", "GrLib.HC").joinToString("\n") { String(File(SHARED, "runtime/$it").readBytes(), Charsets.ISO_8859_1) }
        val skip = setOf("Exit", "Kill", "GetChar", "GetKey", "GetMsg", "GetStr", "GetS", "Busy", "Suspend", "Sleep", "SleepUntil",
            "Ed", "Man", "Help", "throw", "Break", "PutExceptMsg", "Raw", "Refresh", "Yield", "BreakLock", "BreakUnlock")
        Regex("(?m)^native\\s+(?:public\\s+)?[A-Za-z0-9_]+\\s*\\**\\s*([A-Za-z0-9_]+)\\(([^)]*(?:\\([^)]*\\)[^)]*)*)\\);").findAll(txt)
            .map { m ->
                val params = ArrayList<String>(); var depth = 0; val sb = StringBuilder()
                for (ch in m.groupValues[2]) { if (ch == '(') depth++; if (ch == ')') depth--; if (ch == ',' && depth == 0) { params.add(sb.toString().trim()); sb.setLength(0) } else sb.append(ch) }
                if (sb.isNotBlank()) params.add(sb.toString().trim())
                m.groupValues[1] to params
            }.filter { it.first !in skip }.toList()
    }

    private val GFX_NATIVE = Regex("Gr.*|Line|DC.*|Sprite.*|Text.*|Win.*|IsPixCovered0|Mat4x4MulXYZ")

    private fun nativeCall(r: Random): String {
        val (name, params) = natives[r.nextInt(natives.size)]
        // Raster natives loop over the requested area without interrupt checks: huge sizes are probed
        // separately (graphicsHugeArgProbe) so that one unkillable hang does not stall the whole run.
        val gfx = GFX_NATIVE.matches(name)
        fun randInt(r: Random): String = if (gfx) lit(r.nextInt(1400).toLong() - 200) else this.randInt(r)
        val args = ArrayList<String>()
        for (p in params) {
            if (p == "...") { repeat(r.nextInt(4)) { args.add(if (r.nextBoolean()) randInt(r) else randPtr(r)) }; continue }
            args.add(when {
                p.contains("(*") -> if (r.nextInt(3) == 0) "&Cmp" else randInt(r)
                p.contains("fmt") || p.contains("U8 *st") || p.contains("filename") || p.contains("mask") || p.contains("path") || p.contains("dname") ->
                    when (r.nextInt(4)) { 0 -> randFmt(r); 1 -> "\"" + listOf("~/F.TXT", "C:/Home", "::/../..", "C:/Demo/*", "*", "\\\\x", "", "~/../../etc/passwd", "D:/x", "C:/Home/" + "a".repeat(40)).let { it[r.nextInt(it.size)] } + "\""; else -> randPtr(r) }
                p.contains("*") || p.contains("CTask") || p.contains("CDC") -> if (p.contains("CDC") && r.nextBoolean()) "gr.dc" else randPtr(r)
                p.startsWith("F64") -> listOf("1e308", "-1e308", "0.0", "-0.0", "1.5", "1e-320", "(0x7FF8000000000000)(F64)", randInt(r) + "(F64)").let { it[r.nextInt(it.size)] }
                else -> randInt(r)
            })
        }
        return "x=$name(${args.joinToString(",")});"
    }

    @Test fun nativeCallFuzz() {
        val n = iters(150)
        val c = Collector("natives", "HC")
        val fsDir = tmpDir("tosfuzz-nat")
        val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), fsDir)
        val exec: (ByteArray) -> String? = { b -> runProgramCase(b, maxSteps = 60, wallMs = 10_000, flagStkOver = true, fs = fs).first }
        log("[fuzz:natives] ${natives.size} natives: ${natives.joinToString(",") { it.first }}")
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("natives", i)
            val r = Random(seed)
            val src = ("I64 Cmp(I64 a,I64 b){return a-b;}\n" + vmProgram(r, 25) { rr -> if (rr.nextInt(4) == 0) randStmt(rr) else nativeCall(rr) }).toByteArray(Charsets.ISO_8859_1)
            val (sig, detail) = runProgramCase(src, maxSteps = 60, wallMs = 10_000, flagStkOver = true, fs = fs)
            if (sig != null) c.found(seed, sig, detail, src, if (sig.startsWith("HANG")) null else exec, 40_000)
        }
        fsDir.deleteRecursively()
        c.finish(n)
    }

    /** draw_it callbacks run outside vm.run (Kernel.compose): host exceptions there escape step(). */
    @Test fun drawItCallbackFuzz() {
        val n = iters(80)
        val c = Collector("draw-it", "HC")
        val exec: (ByteArray) -> String? = { b -> runProgramCase(b, maxSteps = 40, wallMs = 10_000, flagStkOver = true).first }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("draw-it", i)
            val r = Random(seed)
            val sb = StringBuilder("I64 Cmp(I64 a,I64 b){return a-b;}\nU8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0=\"hello\",*p; I64 *q,x,i; F64 d;\n")
            sb.append("U0 DrawIt(CTask *task,CDC *dc){\n")
            repeat(6) { sb.append("  ").append(if (r.nextBoolean()) randStmt(r) else nativeCall(r)).append("\n") }
            sb.append("}\nFs->draw_it=&DrawIt; Sleep(200); \"FUZZDONE\\n\";\n")
            val src = sb.toString().toByteArray(Charsets.ISO_8859_1)
            val (sig, detail) = runProgramCase(src, maxSteps = 40, wallMs = 10_000, flagStkOver = true)
            if (sig != null) c.found(seed, sig, detail, src, if (sig.startsWith("HANG")) null else exec, 30_000)
        }
        c.finish(n)
    }


    /** One huge-size call per graphics native (each in its own kernel); the first unkillable hang ends the probe. */
    @Test fun graphicsHugeArgProbe() {
        val c = Collector("gfx-huge", "HC")
        val calls = listOf(
            "GrRect(gr.dc,0,0,0x7FFFFFFF,0x7FFFFFFF);", "GrFillCircle(gr.dc,100,100,0,0x7FFFFFFF);", "GrFillSemiCircle(gr.dc,100,100,0,0x7FFFFFFF,1);",
            "GrLineFat3(gr.dc,0,0,0,100,100,0,0x7FFFFFFF);", "GrHLine(gr.dc,-0x7FFFFFFFFFFF,0x7FFFFFFFFFFF,10);", "GrVLine(gr.dc,10,-0x7FFFFFFFFFFF,0x7FFFFFFFFFFF);",
            "Line(NULL,0,0,0,0x7FFFFFFFFFFF,0x7FFFFFFFFFFF,0,&Plot);", "GrCircle(gr.dc,100,100,0x7FFFFFFF);", "GrEllipse(gr.dc,100,100,0x7FFFFFFF,0x7FFFFFFF);",
            "GrFloodFill(gr.dc,10,10);", "GrBorder(gr.dc,0,0,0x7FFFFFFF,0x7FFFFFFF);", "GrPrint(gr.dc,0,0,\"%*d\",0x7FFFFFF,1);")
        for ((i, call) in calls.withIndex()) {
            if (leakedThreads >= 1) { log("[fuzz:gfx-huge] stopping: an unkillable hang is already running"); break }
            c.ran = i + 1
            val src = "Bool Plot(U8 *a,I64 x,I64 y,I64 z){return TRUE;}\ntry{$call}catch{Fs->catch_except=TRUE;}\n\"FUZZDONE\\n\";\n".toByteArray()
            val (sig, detail) = runProgramCase(src, maxSteps = 30, wallMs = 8_000)
            log("[fuzz:gfx-huge] $call -> ${sig ?: "ok"}")
            if (sig != null) c.found(i.toLong(), sig, detail, src, null)
        }
        c.finish(calls.size)
    }


    /** Format width/repeat taken from arguments ("*" and %h<n>c): one call per program; the first unkillable hang ends it. */
    @Test fun formatHugeArgProbe() {
        val c = Collector("fmt-huge", "HC")
        val calls = listOf("StrPrint(b,\"%h*c\",0x7FFFFFFFFFFF,'x');", "StrPrint(b,\"%h*c\",0x7FFFFFFFFFFF,0);", "Print(\"%*d\",0x7FFFFFFF,1);",
            "MStrPrint(\"%-*s\",0x7FFFFFFF,\"a\");", "MStrPrint(\"%.*f\",0x7FFFFFFF,1.5);", "Print(\"%h99999999999c\",'x');", "Print(\"%*d\",0x7FFFFFFFFFFFFFFF,1);")
        for ((i, call) in calls.withIndex()) {
            if (leakedThreads >= 1) { log("[fuzz:fmt-huge] stopping: an unkillable hang is already running"); break }
            c.ran = i + 1
            val src = "U8 b[64];\ntry{$call}catch{Fs->catch_except=TRUE;}\n\"FUZZDONE\\n\";\n".toByteArray()
            val (sig, detail) = runProgramCase(src, maxSteps = 30, wallMs = 8_000)
            log("[fuzz:fmt-huge] $call -> ${sig ?: "ok"}")
            if (sig != null) c.found(i.toLong(), sig, detail, src, null)
        }
        c.finish(calls.size)
    }

    // ================================================================ 3. paths / LayeredFs

    private val pathParts = listOf("..", ".", "", "C:", "c:", "D:", "::", "~", "/", "\\", "//", "\\\\", "etc", "passwd", "/etc/passwd",
        "/data/data/io.github.templeosmobile", "\u0000", "a".repeat(38), "b".repeat(39), "Home", "Demo", "Games", "Maze.HC", "files", "deleted.txt",
        ".tmp-x", "..\\..", "C:/../..", "%2e%2e", "\u2215", "\uFF0E\uFF0E", " .. ", "...", "x/../../../../y", "\r\n", "\u00e9", "\uD83D\uDE00",
        "\uD800", "*", "?", "<", "|", "\"", ":", "con", "nul", "~/..", "::/..", "C:\\..\\..\\", "Doc", "HelpIndex.DD", "\u007f", "\t", " ", "../\u0301", "\u0301", "/\u0301..", "..\u0301", "e\u0301")

    private fun randPath(r: Random): String {
        if (r.nextInt(20) == 0) return (0 until r.nextInt(80) + 20).joinToString("/") { "d" + "x".repeat(r.nextInt(37)) }
        val sb = StringBuilder()
        if (r.nextBoolean()) sb.append(listOf("C:/", "c:", "::/", "~/", "/", "", "D:/", "C:", "C:\\").let { it[r.nextInt(it.size)] })
        repeat(r.nextInt(8)) {
            sb.append(if (r.nextInt(6) == 0) String(CharArray(r.nextInt(5) + 1) { (r.nextInt(0x3000)).toChar() }) else pathParts[r.nextInt(pathParts.size)])
            sb.append(if (r.nextInt(4) == 0) "\\" else "/")
        }
        return sb.toString()
    }

    @Test fun pathAndLayeredFsFuzz() {
        val n = iters(4000)
        val c = Collector("fs", "txt")
        val parent = tmpDir("tosfuzz-fs")
        val overlay = File(parent, "overlay").apply { mkdirs() }
        val secret = "SECRET-${System.nanoTime()}"
        File(parent, "secret.txt").writeText(secret)
        File(overlay, "secret.txt").writeText(secret)
        val filesCanon = File(overlay, "files").canonicalFile
        val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), overlay, quotaBytes = 4L shl 20)
        fun violation(): String? {
            val top = parent.listFiles()!!.map { it.name }.sorted()
            if (top != listOf("overlay", "secret.txt")) return "escape:extra-file-in-parent:$top"
            if (File(parent, "secret.txt").readText() != secret || File(overlay, "secret.txt").readText() != secret) return "escape:secret-modified"
            val ov = overlay.listFiles()!!.map { it.name }.filter { it !in setOf("files", "deleted.txt", "deleted.txt.tmp", "secret.txt") }
            if (ov.isNotEmpty()) return "escape:extra-file-in-overlay-root:$ov"
            return null
        }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("fs", i)
            val r = Random(seed)
            val p1 = randPath(r); val p2 = randPath(r)
            val op = r.nextInt(13)
            val desc = "op=$op p1=${p1.map { if (it.code in 32..126) it.toString() else "\\u%04x".format(it.code) }.joinToString("")} p2=${p2.map { if (it.code in 32..126) it.toString() else "\\u%04x".format(it.code) }.joinToString("")}"
            val sig: String? = try {
                // normalize invariants
                var bad: String? = null
                for (cwd in listOf("C:/Home", "C:/", "C:/Demo/Games")) {
                    val norm = Paths.normalize(cwd, p1)
                    if (norm != null) {
                        if (!norm.startsWith("C:/")) bad = "normalize:not-C-rooted"
                        else if (norm.split('/').any { it == ".." || it == "." } || norm.substring(3).contains("//")) bad = "normalize:dot-segment"
                        else if (norm.any { it.code < 32 }) bad = "normalize:control-char"
                        else {
                            val host = File(filesCanon, norm.removePrefix("C:/"))
                            val hc = try { host.canonicalPath } catch (e: java.io.IOException) { null }
                            if (hc != null && !(hc == filesCanon.path || hc.startsWith(filesCanon.path + File.separator))) bad = "normalize:host-escape"
                        }
                    }
                }
                if (bad != null) bad else {
                    when (op) {
                        0 -> fs.readFile(p1)?.let { if (String(it, Charsets.ISO_8859_1).contains(secret)) "escape:read-secret" else null }
                        1 -> { fs.writeFile(p1, "data$i".toByteArray()); null }
                        2 -> { fs.mkdir(p1); null }
                        3 -> { fs.delete(p1, r.nextBoolean()); null }
                        4 -> { fs.move(p1, p2); null }
                        5 -> { fs.list(p1)?.forEach { e -> if (e.name == "secret.txt") throw IllegalStateException("listed secret") }; null }
                        6 -> { fs.stat(p1); fs.exists(p1); fs.isDir(p1); null }
                        7 -> { fs.restoreOriginal(p1); null }
                        8 -> { fs.isOriginal(p1); fs.hasBundledOriginal(p1); null }
                        9 -> { val d = Paths.normalize("C:/", p1); if (d != null) { fs.mkdir(Paths.parent(d)) }; fs.writeFile(p1, ByteArray(r.nextInt(3000))); fs.move(p1, p2); null }
                        10 -> { Paths.matches(p1, p2); null }
                        11 -> { Paths.parent(p1); Paths.name(p1); null }
                        else -> { fs.list("C:/")?.size; fs.writeFile(p1, ByteArray(0)); fs.delete(p1); null }
                    }
                }
            } catch (e: FsError) { null } catch (e: Throwable) { sigOf(e) + ":" + e.toString().take(120).replace('\n', ' ') }
            val esc = violation()
            val s = esc ?: sig
            if (s != null) {
                val key = s.substringBefore(':') + ":" + s.substringAfter(':').substringBefore(':')
                c.found(seed, key, "$desc\n$s", desc.toByteArray(), null)
                if (esc != null) break
            }
        }
        parent.deleteRecursively()
        c.finish(n)
    }

    // ================================================================ 4. sprites

    private val spriteCorpus: List<ByteArray> by lazy {
        val res = ArrayList<ByteArray>()
        val dirs = listOf("bundled-fs/Demo/Games", "bundled-fs/Demo/Graphics", "bundled-fs/Apps", "bundled-fs/Demo")
        for (d in dirs) File(SHARED, d).walkTopDown().filter { it.isFile && it.name.endsWith(".HC") }.sortedBy { it.path }.forEach { f ->
            SourceFile.parse(f.name, f.readBytes()).bins.toSortedMap().values.forEach { if (it.size in 1..20000) res.add(it) }
        }
        res
    }

    private fun mutateBlob(r: Random, b0: ByteArray): ByteArray {
        var b = b0.copyOf()
        repeat(1 + r.nextInt(4)) {
            when (r.nextInt(6)) {
                0 -> repeat(1 + r.nextInt(6)) { if (b.isNotEmpty()) b[r.nextInt(b.size)] = r.nextInt(256).toByte() }
                1 -> if (b.isNotEmpty()) b = b.copyOfRange(0, r.nextInt(b.size))
                2 -> if (b.size >= 5) { // overwrite an I32 field with an interesting value
                    val o = r.nextInt(b.size - 4); val v = interesting[r.nextInt(interesting.size)].toInt()
                    for (j in 0..3) b[o + j] = (v shr (8 * j)).toByte()
                }
                3 -> if (b.isNotEmpty()) b[r.nextInt(b.size)] = (r.nextInt(32)).toByte() // element type byte
                4 -> b = ByteArray(r.nextInt(64)) { r.nextInt(256).toByte() }
                else -> b = b + ByteArray(r.nextInt(16)) { r.nextInt(256).toByte() }
            }
        }
        return b
    }

    @Test fun spriteFuzz() {
        val n = iters(150)
        val c = Collector("sprite", "bin")
        log("[fuzz:sprite] corpus: ${spriteCorpus.size} sprite blobs")
        // native fast paths on a shared kernel; Sprite3 (HolyC GrLib) on fresh kernels for a subset
        var k: Kernel? = null
        fun nativeExec(blob: ByteArray, kk: Kernel): String? {
            val a = kk.mem.malloc(blob.size + 64L); kk.mem.fill(a, 0, blob.size + 64); kk.mem.writeBytes(a, blob)
            return try {
                try { kk.callHolyC("SpriteSize", a.toLong()) } catch (e: VmFault) {} catch (e: VmUncaught) {}
                try { kk.callHolyC("SpriteElemSize", a.toLong() - kk.o.member("CSprite", "start")) } catch (e: VmFault) {} catch (e: VmUncaught) {}
                kk.mem.free(a.toLong()); null
            } catch (e: VmKill) { null }
        }
        val freshNative: (ByteArray) -> String? = { b -> isolated(10_000) { nativeExec(b, Kernel(TestEnv(), "sp").also { it.boot() }) }.first }
        fun sprite3Src(blobAddrExpr: String, r: Random): String {
            val call = listOf("Sprite3(dc,%d,%d,0,p);", "Sprite3B(dc,%d,%d,0,p);", "Sprite3ZB(dc,%d,%d,0,p,0.5);", "Sprite3(dc,%d,%d,0,p,TRUE);",
                "SpriteExtents(p,&x0,&x1,&y0,&y1);", "q=DC2Sprite(dc);", "q=SpriteInterpolate(0.5,p,p);")
            val sb = StringBuilder("U8 *p=$blobAddrExpr,*q; I64 x0,x1,y0,y1; CDC *dc=DCAlias;\n")
            repeat(4) { sb.append("try{").append(call[r.nextInt(call.size)].format(r.nextInt(800) - 80, r.nextInt(600) - 60)).append("}catch{Fs->catch_except=TRUE;}\n") }
            sb.append("DCDel(dc);\"FUZZDONE\\n\";\n")
            return sb.toString()
        }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("sprite", i)
            val r = Random(seed)
            val blob = if (spriteCorpus.isNotEmpty() && r.nextInt(8) != 0) mutateBlob(r, spriteCorpus[r.nextInt(spriteCorpus.size)]) else ByteArray(r.nextInt(48)) { r.nextInt(256).toByte() }
            if (k == null || i % 50 == 0) k = Kernel(TestEnv(), "sp").also { it.boot() }
            val kk = k
            val (sig, detail) = isolated(10_000, onTimeout = { kk.vm.interrupt = true }) { nativeExec(blob, kk) }
            if (sig != null) { k = null; val conf = freshNative(blob); if (conf != null) c.found(seed, "native:$conf", detail, blob, { b -> freshNative(b)?.let { "native:$it" } }) }
            if (i % 3 == 0) {
                val holder = AtomicReference(0L)
                val tmpl = sprite3Src("BLOB", r)
                val exec: (ByteArray) -> String? = { b ->
                    runProgramCase(tmpl.replace("BLOB", "0x" + java.lang.Long.toHexString(holder.get())).toByteArray(), maxSteps = 30, wallMs = 10_000) { kk2 ->
                        val a = kk2.mem.malloc(b.size + 64L); kk2.mem.fill(a, 0, b.size + 64); kk2.mem.writeBytes(a, b); holder.set(a.toLong())
                    }.first
                }
                // the address is deterministic for a fresh kernel; compute it once
                val probe = Kernel(TestEnv(), "sp").also { it.boot() }
                holder.set(probe.mem.malloc(blob.size + 64L).toLong())
                val res = exec(blob)
                if (res != null) c.found(seed, "sprite3:$res", "template:\n$tmpl", blob, { b -> exec(b)?.let { "sprite3:$it" } })
            }
        }
        c.finish(n)
    }

    // ================================================================ 5. DolDoc viewer

    private fun headless(): Pair<HeadlessEnv, File> { val d = tmpDir("tosfuzz-ui"); return HeadlessEnv(d) to d }

    private fun mutateDoc(r: Random, b0: ByteArray): ByteArray {
        var b = mutateBlob(r, b0)
        if (r.nextInt(3) == 0) {
            val ins = listOf("\$", "\$\$", "\$TX,\"", "\$ID,99999\$", "\$ID,-99999\$", "\$TX+CX,\"" + "x".repeat(r.nextInt(500)) + "\"\$", "\$WW,0\$", "\$CL\$",
                "\$FG,-5\$", "\$BG,999999999999\$", "\$LK,\"a\",A=\"FI:::/../../etc/passwd\"\$", "\$TR,\"\"\$", "\$SP,\"\",BI=1\$", "\$UL,1\$", "\$IV,1\$",
                "\t".repeat(r.nextInt(50)), "\u0000", "\$MA,\"x\",LM=\"Dir;\"\$", "\$TX,\"\\\"\$", "\$BT,\"\"\$", "\$ID,2147483647\$")
            val s = ins[r.nextInt(ins.size)].toByteArray(Charsets.ISO_8859_1)
            val i = r.nextInt(b.size + 1); b = b.copyOfRange(0, i) + s + b.copyOfRange(i, b.size)
        }
        return b
    }

    @Test fun docViewerFuzz() {
        val n = iters(600)
        val c = Collector("docviewer", "DD")
        val (env, dir) = headless()
        val sh = Shell(env); sh.resize(360, 640)
        val surf = Surface(1200, 900, sh.font)
        fun exec(doc: ByteArray, r: Random): String? = try {
            env.fs.writeFile("C:/Home/Fuzz.DD", doc)
            val app = DocViewerApp(sh, "C:/Home/Fuzz.DD")
            if (r.nextBoolean()) app.restoreTop(listOf(0, -1, 5, 100000, Int.MAX_VALUE, Int.MIN_VALUE, r.nextInt())[r.nextInt(7)])
            for (w in listOf(8, 100, 360, 1200, 0)) {
                val rect = Rect(0, 0, w, 1 + r.nextInt(899))
                app.draw(surf, rect)
                app.scroll(0, r.nextInt(2000) - 1000, rect)
                app.key(0, listOf(Keys.SC_CURSOR_DOWN, Keys.SC_PAGE_DOWN, Keys.SC_PAGE_UP, Keys.SC_CURSOR_UP)[r.nextInt(4)].toLong(), true)
                app.draw(surf, rect)
            }
            app.saveState(); null
        } catch (e: FsError) { null } catch (e: Throwable) { sigOf(e) }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("docviewer", i)
            val r = Random(seed)
            val doc = if (r.nextInt(10) == 0) ByteArray(r.nextInt(3000)) { r.nextInt(256).toByte() } else mutateDoc(r, corpusDD[r.nextInt(corpusDD.size)].second)
            val sig = exec(doc, Random(seed + 1))
            if (sig != null) c.found(seed, sig, "", doc, { b -> exec(b, Random(seed + 1)) })
        }
        dir.deleteRecursively()
        c.finish(n)
    }

    // ================================================================ 6. session restore / settings / JSON

    @Test fun jsonAndCatalogFuzz() {
        val n = iters(5000)
        val c = Collector("json", "json")
        val catalog = String(File(SHARED, "program-manifests/catalog.json").readBytes(), Charsets.UTF_8)
        // Catalog.load swallows Exception (not Error): anything else escaping parse()/load() is a defect.
        fun exec(s: String): String? = try {
            try { Catalog.parse(s) } catch (e: Exception) {}
            try { Json.parse(s) } catch (e: Exception) {}
            null
        } catch (e: Throwable) { sigOf(e) }
        val seeds = listOf("[".repeat(100_000), "{\"a\":".repeat(50_000), "{\"programs\":" + "[".repeat(20000))
        for ((j, s) in seeds.withIndex()) exec(s)?.let { c.found(-1L - j, it, "", s.toByteArray(), null) }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("json", i)
            val r = Random(seed)
            val base = if (r.nextBoolean()) catalog.substring(0, minOf(catalog.length, 3000)) + "]}" else catalog
            val m = String(mutateBlob(r, base.toByteArray(Charsets.ISO_8859_1)), Charsets.ISO_8859_1)
            exec(m)?.let { sig -> c.found(seed, sig, "", m.toByteArray(Charsets.ISO_8859_1), { b -> exec(String(b, Charsets.ISO_8859_1)) }) }
            // settings decode must never throw
            try { Settings.decode(m.take(200)) } catch (e: Throwable) { c.found(seed, "Settings.decode:" + sigOf(e), "", m.take(200).toByteArray(), null) }
        }
        c.finish(n)
    }

    private fun realSession(env: HeadlessEnv): String {
        val sh = Shell(env); sh.resize(800, 360)
        env.fs.writeFile("C:/Home/Pic.GR", ByteArray(32 + 320 * 240).also { it[16] = 64; it[17] = 1; it[20] = 64; it[21] = 1; it[24] = 240.toByte() })
        Launch.files(sh, "C:/Home/Examples"); Launch.doc(sh, "C:/Doc/HelpIndex.DD"); Launch.editor(sh, "C:/Home/Examples/Hello.HC")
        Launch.god(sh); Launch.about(sh); Launch.settings(sh); sh.open(PaintApp(sh, "C:/Home/Pic.GR"))
        sh.saveSession()
        val s = env.session!!
        sh.windows.toList().forEach { it.app.close() }
        return s + "win\tterminal\t0\t0\t300\t200\t0\t0\tdir=C:/Home\thist=Dir;\u0001\"x\";\n"
    }

    @Test fun sessionRestoreFuzz() {
        val n = iters(400)
        val c = Collector("session", "txt")
        val (env, dir) = headless()
        val base = realSession(env)
        log("[fuzz:session] base session:\n$base")
        val kinds = listOf("terminal", "editor", "files", "doc", "god", "paint", "settings", "about", "program", "bogus")
        val keys = listOf("dir", "hist", "path", "draft", "row", "col", "top", "id")
        val vals = listOf("-1", "2147483647", "-2147483648", "99999999999999999999", "NaN", "", "C:/../../etc/passwd", "/etc/passwd", "D:/x",
            "C:/Home/Pic.GR", "C:/Doc/HelpIndex.DD", "C:/Home", "\\t\\n\\e", "x".repeat(5000), "\u0000", "C:/Home/Examples/Hello.HC", "0", "1e9")
        fun exec(text: String): String? {
            env.session = text
            return isolated(15_000) {
                val sh = Shell(env)
                try {
                    sh.resize(360, 640); sh.restoreSession(); sh.tick()
                    sh.resize(800, 360); sh.tick()
                    sh.saveSession(); null
                } finally { sh.windows.toList().forEach { try { it.app.close() } catch (_: Throwable) {} } }
            }.first
        }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("session", i)
            val r = Random(seed)
            val text = when (r.nextInt(3)) {
                0 -> String(mutateBlob(r, base.toByteArray(Charsets.ISO_8859_1)), Charsets.ISO_8859_1)
                1 -> base.lines().filter { !it.startsWith("win\tterminal") || r.nextBoolean() }.joinToString("\n") { l ->
                    if (!l.startsWith("win")) l else l.split('\t').mapIndexed { j, f -> if (j >= 2 && r.nextInt(3) == 0) (if (j < 8) vals[r.nextInt(vals.size)] else keys[r.nextInt(keys.size)] + "=" + vals[r.nextInt(vals.size)]) else f }.joinToString("\t")
                }
                else -> "v1\nsettings\t" + (0 until r.nextInt(6)).joinToString(";") { listOf("d", "s", "o", "u", "c", "")[r.nextInt(6)] + "=" + vals[r.nextInt(vals.size)] } + "\n" +
                    (0 until r.nextInt(4) + 1).joinToString("") {
                        "win\t" + kinds[r.nextInt(kinds.size).let { k -> if (kinds[k] == "program" || kinds[k] == "terminal") (k + 1) % kinds.size else k }] + "\t" +
                            (0 until 6).joinToString("\t") { vals[r.nextInt(vals.size)] } + (0 until r.nextInt(4)).joinToString("") { "\t" + keys[r.nextInt(keys.size)] + "=" + vals[r.nextInt(vals.size)] } + "\n"
                    }
            }
            val sig = exec(text)
            if (sig != null) c.found(seed, sig, "", text.toByteArray(Charsets.ISO_8859_1), { b -> exec(String(b, Charsets.ISO_8859_1)) })
        }
        dir.deleteRecursively()
        c.finish(n)
    }

    // ================================================================ 7. Paint .GR loading

    @Test fun paintGrFuzz() {
        val n = iters(1500)
        val c = Collector("paint", "GR")
        val (env, dir) = headless()
        val sh = Shell(env); sh.resize(360, 640)
        val surf = Surface(400, 400, sh.font)
        val real = File(SHARED, "bundled-fs/Demo/Games/Stadium/StadiumBG.GR").readBytes()
        fun exec(b: ByteArray): String? = try {
            env.fs.writeFile("C:/Home/Fuzz.GR", b)
            val p = PaintApp(sh, "C:/Home/Fuzz.GR")
            p.draw(surf, Rect(0, 0, 400, 400)); null
        } catch (e: FsError) { null } catch (e: Throwable) { sigOf(e) }
        fun hdr(gw: Int, wi: Int, gh: Int, flags: Int, size: Int): ByteArray {
            val b = ByteArray(maxOf(32, size))
            fun p32(o: Int, v: Int) { for (j in 0..3) b[o + j] = (v shr (8 * j)).toByte() }
            p32(16, gw); p32(20, wi); p32(24, gh); p32(28, flags); return b
        }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("paint", i)
            val r = Random(seed)
            fun iv() = if (r.nextBoolean()) interesting[r.nextInt(interesting.size)].toInt() else r.nextInt(700) - 100
            val b = when (r.nextInt(3)) {
                0 -> mutateBlob(r, real)
                1 -> hdr(iv(), iv(), iv(), r.nextInt(4), r.nextInt(4000))
                else -> ByteArray(r.nextInt(80)) { r.nextInt(256).toByte() }
            }
            val sig = exec(b)
            if (sig != null) c.found(seed, sig, "", b, { x -> exec(x) })
        }
        dir.deleteRecursively()
        c.finish(n)
    }

    // ================================================================ replay

    /** Replays one saved input: -Dtempleos.fuzz.replay=<file> [-Dtempleos.fuzz.replay.target=run|compile|paint|doc|json|native-sprite]. */
    @Test fun replay() {
        val path = prop("templeos.fuzz.replay", "TEMPLEOS_FUZZ_REPLAY") ?: return
        val b = File(path).readBytes()
        val target = prop("templeos.fuzz.replay.target", "TEMPLEOS_FUZZ_REPLAY_TARGET") ?: "run"
        val res: Pair<String?, String> = when (target) {
            "compile" -> isolated(60_000) { compileOnly(Kernel(TestEnv(), "r").also { it.boot() }, b, null) }
            "paint" -> isolated(60_000) { val (env, _) = headless(); val sh = Shell(env); sh.resize(360, 640); env.fs.writeFile("C:/Home/Fuzz.GR", b); PaintApp(sh, "C:/Home/Fuzz.GR").draw(Surface(400, 400, sh.font), Rect(0, 0, 400, 400)); null }
            "doc" -> isolated(60_000) { val (env, _) = headless(); val sh = Shell(env); sh.resize(360, 640); env.fs.writeFile("C:/Home/Fuzz.DD", b); val a = DocViewerApp(sh, "C:/Home/Fuzz.DD"); for (w in listOf(8, 100, 360, 1200, 0)) a.draw(Surface(1200, 900, sh.font), Rect(0, 0, w, 400)); null }
            "json" -> isolated(60_000) { Json.parse(String(b, Charsets.ISO_8859_1)); null }
            else -> runProgramCase(b, maxSteps = 200, wallMs = 60_000, flagStkOver = true, fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), tmpDir("tosfuzz-replay")))
        }
        log("[fuzz:replay] $target $path -> ${res.first ?: "ok"}\n${res.second}")
        if (res.first != null) fail("replay: ${res.first}")
    }

    // ================================================================ source container (binary trailer)

    @Test fun sourceFileTrailerFuzz() {
        val n = iters(5000)
        val c = Collector("sourcefile", "HC")
        fun exec(b: ByteArray): String? = try { SourceFile.parse("x", b); textPart(b); null } catch (e: Throwable) { sigOf(e) }
        for (i in 0 until n) {
            if (c.tooManyLeaks) { log("[fuzz:${c.target}] stopping after $i iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            val seed = caseSeed("sourcefile", i)
            val r = Random(seed)
            val b = java.io.ByteArrayOutputStream()
            b.write("\"hi\";".toByteArray()); b.write(0)
            repeat(r.nextInt(4)) {
                fun w32(v: Int) { for (j in 0..3) b.write(v shr (8 * j)) }
                w32(r.nextInt(5)); w32(0)
                w32(if (r.nextBoolean()) interesting[r.nextInt(interesting.size)].toInt() else r.nextInt(64)); w32(0)
                b.write(ByteArray(r.nextInt(64)))
            }
            val bytes = b.toByteArray()
            exec(bytes)?.let { c.found(seed, it, "", bytes, ::exec) }
        }
        c.finish(n)
    }
}
