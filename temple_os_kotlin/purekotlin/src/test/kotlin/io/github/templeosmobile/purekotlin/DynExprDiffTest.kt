package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.dynexpr.DynExpr
import io.github.templeosmobile.core.dynexpr.DynFunctions
import io.github.templeosmobile.core.dynexpr.DynScope
import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.Kernel
import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.ui.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File

const val CARTESIAN = "C:/Demo/Graphics/Cartesian.HC"

/**
 * Cartesian with its globals x, y, y_last on [engine], waiting for a formula; [run] calls the kernel's
 * ExePrint native with "ToF64(%s);" and a text, exactly as Cartesian's loop does, on both engines (the
 * interpreter compiles and runs the text; a native kernel evaluates it with core/dynexpr).
 */
class ExeHarness(val engine: Engine) {
    val k: Kernel
    private val fmt: Long
    private val buf: Long
    private val exe: Long
    private val gx: GlobalSym; private val gy: GlobalSym; private val gyl: GlobalSym

    init {
        val (kk, _) = bootProgram(CARTESIAN, engine)
        k = kk
        advanceTo(k, 300)
        fmt = k.mem.malloc(16).toLong().also { k.mem.writeBytes(it.toInt(), latin1("ToF64(%s);\u0000")) }
        buf = k.mem.malloc(8192).toLong()
        exe = Program.FPTR_NATIVE or k.vm.natives.find("ExePrint")!!.index.toLong()
        gx = k.prog.globals["x"] as GlobalSym; gy = k.prog.globals["y"] as GlobalSym; gyl = k.prog.globals["y_last"] as GlobalSym
    }

    /** One ExePrint call with x=[x], y=y_last=0: [result, x, y, y_last, ticks, outcome] ("" | "out:console text" | "ex:Ch:msg"). */
    fun run(text: String, x: Double): List<String> {
        k.mem.st8(gx.addr, x.toRawBits()); k.mem.st8(gy.addr, 0); k.mem.st8(gyl.addr, 0)
        val b = latin1(text)
        k.mem.writeBytes(buf.toInt(), b); k.mem.st1(buf.toInt() + b.size, 0)
        k.console.clear()
        val ticks0 = k.vm.ticksExecuted
        var r = 0L
        var ex: String? = null
        try { r = k.vm.callFunction(k.adamTask!!, exe, fmt, buf) }
        catch (u: VmUncaught) { ex = "ex:${k.vm.chStr(u.ch)}:${u.message}" }
        catch (f: VmFault) { ex = "ex:${k.vm.chStr(f.ch)}:${f.message}" }
        val out = k.console.plainText().trim()
        val outcome = ex ?: if (out.isNotEmpty()) "out:$out" else ""
        return listOf(hex(r), hex(k.mem.ld8(gx.addr)), hex(k.mem.ld8(gy.addr)), hex(k.mem.ld8(gyl.addr)), (k.vm.ticksExecuted - ticks0).toString(), outcome)
    }

    /** Cartesian's loop alone: y=-ExePrint("ToF64(%s);",st)(F64) for x = -320..320 (641 points); returns the wall time in ns. */
    fun graph(text: String): Long {
        val b = latin1(text)
        k.mem.writeBytes(buf.toInt(), b); k.mem.st1(buf.toInt() + b.size, 0)
        val t = k.adamTask!!
        val st = System.nanoTime()
        for (x in -320..320) {
            k.mem.st8(gx.addr, x.toDouble().toRawBits())
            val r = k.vm.callFunction(t, exe, fmt, buf)
            k.mem.st8(gy.addr, r xor Long.MIN_VALUE)
        }
        return System.nanoTime() - st
    }

    fun close() = k.terminate("done")

    companion object { fun hex(v: Long) = java.lang.Long.toHexString(v) }
}

/**
 * Differential tests of the native expression engine against the interpreter (Pure Terry):
 * the shared Cartesian corpus (shared/test-vectors/dynexpr), a seeded random-expression fuzz, and
 * Cartesian itself run on both engines with typed formulas (frames, console, ticks, globals compared
 * at every 20 ms checkpoint). The interpreter's corpus results are the shared fixture the Swift tests
 * check both Swift engines against.
 */
class DynExprDiffTest {
    private val corpusFile = File(SHARED, "test-vectors/dynexpr/cartesian-corpus.json")
    private val fixtureFile = File(SHARED, "test-vectors/dynexpr/cartesian-interpreter-results.json")

    @Suppress("UNCHECKED_CAST")
    private fun corpus(): Triple<String, List<Double>, List<Map<String, Any?>>> {
        val c = Json.parse(corpusFile.readText()) as Map<String, Any?>
        return Triple(c["template"] as String, (c["samples"] as List<Any?>).map { (it as Number).toDouble() }, c["formulas"] as List<Map<String, Any?>>)
    }

    private fun isOutside(outcome: String) = outcome.startsWith("out:") && outcome.contains("outside the native expression")
    /** A compile error the interpreter printed (ExePrint's red message names the text it compiled). */
    private fun isCompileError(outcome: String) = outcome.startsWith("out:${DynExpr.FILE}:")

    @Test
    fun cartesianCorpusAgainstTheInterpreter() {
        val (template, samples, formulas) = corpus()
        assertEquals("ToF64(%s);", template)
        val terry = ExeHarness(Engine.TERRY)
        val native = ExeHarness(Engine.NATIVE)
        val interp = LinkedHashMap<String, List<List<String>>>()
        class Row(var formulas: Int = 0, var identical: Int = 0, var rejected: Int = 0, var rejectedBothErr: Int = 0, var mismatch: Int = 0)
        val rows = LinkedHashMap<String, Row>()
        val report = StringBuilder()
        val rejectedIds = ArrayList<String>()
        val rejected = ArrayList<String>()
        for (f in formulas) {
            val id = f["id"] as String; val cat = f["cat"] as String; val text = f["text"] as String
            val a = samples.map { terry.run(text, it) }
            val b = samples.map { native.run(text, it) }
            if(id in setOf("invalid-11","unsupported-04","unsupported-05")) {
                // Compare opaque pointer semantics, not offsets from a previous prelude layout.
                if(id=="unsupported-04") {
                    a.forEach {assertEquals("MAlloc(10) allocation",16L,terry.k.mem.msize(Double.fromBits(it[0].toULong(16).toLong()).toLong()))}
                    assertEquals("live allocations are distinct",a.size,a.map {it[0]}.toSet().size)
                } else {
                    val address=if(id=="invalid-11") terry.k.prog.stringAddr(latin1("str")).toLong() else terry.k.mem.ld8(terry.k.o.fsGlobal)
                    a.forEach {assertEquals(ExeHarness.hex(address.toDouble().toRawBits()),it[0])}
                }
            }
            interp[id] = a
            val row = rows.getOrPut(cat) { Row() }
            row.formulas++
            when {
                a == b -> row.identical++
                b.any { isOutside(it[5]) } && b.all { isOutside(it[5]) } -> {
                    if (a.all { isCompileError(it[5]) }) row.rejectedBothErr++ else row.rejected++
                    rejectedIds.add("$id ${text.take(40)}: ${b[0][5].substringAfter("subset: ").substringBefore(";")}")
                    rejected.add(id)
                }
                else -> {
                    row.mismatch++
                    val i = a.indices.first { a[it] != b[it] }
                    report.append("$id [$text] x=${samples[i]}: terry=${a[i]} native=${b[i]}\n")
                }
            }
        }
        assertTrue("the native kernel interpreted bytecode", native.k.vm.instructionsExecuted == 0L)
        assertTrue(native.k.dynExprEvaluations >= formulas.size * samples.size)
        terry.close(); native.close()

        val table = StringBuilder("category       formulas identical rejected(outside subset; interpreter accepted) rejected(both errors) mismatch\n")
        for ((cat, r) in rows) table.append("%-14s %8d %9d %8d %8d %8d\n".format(cat, r.formulas, r.identical, r.rejected, r.rejectedBothErr, r.mismatch))
        val tot = rows.values
        table.append("%-14s %8d %9d %8d %8d %8d\n".format("total", tot.sumOf { it.formulas }, tot.sumOf { it.identical }, tot.sumOf { it.rejected }, tot.sumOf { it.rejectedBothErr }, tot.sumOf { it.mismatch }))
        File("build").mkdirs()
        File("build/dynexpr-corpus.txt").writeText(table.toString() + "\nrejected:\n" + rejectedIds.joinToString("\n") + "\n\nmismatches:\n" + report)
        println(table); println("rejected:\n" + rejectedIds.joinToString("\n")); print(report.toString().take(4000))

        // the interpreter's results: the shared fixture (written on request, otherwise they must equal it)
        val json = fixtureJson(samples, interp)
        if (System.getProperty("templeos.dynexpr.writefixture") == "true" || !fixtureFile.exists()) fixtureFile.writeText(json)
        else {
            @Suppress("UNCHECKED_CAST")
            val expected=(Json.parse(fixtureFile.readText()) as Map<*,*>)["results"] as Map<String,List<List<String>>>
            assertEquals(expected.keys,interp.keys)
            for((id,actual) in interp) {
                val want=expected.getValue(id)
                if(id in setOf("invalid-11","unsupported-04","unsupported-05")) assertEquals("pointer expression state",want.map {it.drop(1)},actual.map {it.drop(1)})
                else assertEquals("interpreter fixture: $id",want,actual)
            }
        }

        // outside-subset rejections: the 'unsupported' category and the string literal of 'invalid' (the interpreter
        // passes its address to ToF64); everything else must agree exactly
        assertEquals(listOf("invalid-11", "unsupported-01", "unsupported-02", "unsupported-03", "unsupported-04", "unsupported-05", "unsupported-07"), rejected)
        assertEquals(report.toString().take(3000), 0, tot.sumOf { it.mismatch })
    }

    private fun fixtureJson(samples: List<Double>, interp: Map<String, List<List<String>>>): String {
        fun js(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t") + "\""
        val sb = StringBuilder()
        sb.append("{\n \"version\": 1,\n")
        sb.append(" \"about\": \"Results of the Kotlin interpreter (Pure Terry) for shared/test-vectors/dynexpr/cartesian-corpus.json: Cartesian booted on the interpreter, then for each formula and sample ExePrint(\\\"ToF64(%s);\\\",formula) called through the kernel's native with x=sample, y=y_last=0. Each sample is [result bits, x, y, y_last (F64 bits, hex), budget ticks consumed, outcome], outcome \\\"\\\" (ran, nothing printed), \\\"out:<console text>\\\" (what it printed: a compile error's red message, after which ExePrint returned the last value, or the program's own output) or \\\"ex:<exception>:<message>\\\" (raised). Produced by temple_os_kotlin/purekotlin DynExprDiffTest (-Dtempleos.dynexpr.writefixture=true); the Swift interpreter and both native engines are checked against it.\",\n")
        sb.append(" \"samples\": [").append(samples.joinToString(", ")).append("],\n")
        sb.append(" \"results\": {\n")
        sb.append(interp.entries.joinToString(",\n") { (id, rs) ->
            "  " + js(id) + ": [" + rs.joinToString(", ") { r -> "[" + r.joinToString(",") { js(it) } + "]" } + "]"
        })
        sb.append("\n }\n}\n")
        return sb.toString()
    }

    // ------------------------------------------------------------ fuzz

    /** Random expressions over the supported grammar (seeded; the Swift test uses the same generator). */
    class Gen(seed: Long) {
        private var s = seed
        /** SplitMix64, so the Swift port draws the same numbers. */
        private fun next(): Long { s += -0x61c8864680b583ebL; var z = s; z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L; z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L; return z xor (z ushr 31) }
        fun int(n: Int): Int = ((next() ushr 1) % n).toInt()
        private fun <T> pick(xs: List<T>): T = xs[int(xs.size)]

        private val lits = listOf("0", "1", "2", "3", "7", "10", "100", "255", "256", "1000", "0x10", "0xFF", "0x7FFFFFFFFFFFFFFF", "0xFFFFFFFFFFFFFFFF",
            "0b101", "'A'", "'AB'", "0.5", "1.5", "2.", ".25", "1e3", "1e-3", "3.14159", "1e308", "12345678901234567890", "0.0", "-1", "-0.5")
        private val consts = listOf("pi", "exp_1", "eps", "I64_MAX", "I64_MIN", "U8_MAX", "U32_MAX", "TRUE", "FALSE", "NULL", "inf", "log2_10", "sqrt2")
        private val vars = listOf("x", "y", "y_last")
        private val bin = listOf("+", "-", "*", "/", "%", "`", "<<", ">>", "&", "|", "^", "<", ">", "<=", ">=", "==", "!=", "&&", "||", "^^")
        private val casts = listOf("I64", "U64", "I32", "U32", "I16", "U16", "I8", "U8", "Bool", "F64")
        private val assigns = listOf("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=")
        private val fns = DynFunctions.PARAMS.filterKeys { !it.startsWith("Rand") && it != "tS" }.entries.toList()

        fun expr(depth: Int): String {
            if (depth <= 0) return when (int(3)) { 0 -> pick(lits); 1 -> pick(consts); else -> pick(vars) }
            return when (int(13)) {
                0, 1 -> pick(vars)
                2 -> pick(lits)
                3 -> { val e = expr(depth - 1); pick(listOf("-", "!", "~", "+")) + (if (e.startsWith("-") || e.startsWith("+")) " " else "") + e }
                4, 5 -> "(" + expr(depth - 1) + pick(bin) + expr(depth - 1) + ")"
                6 -> { // an operator sequence without parentheses: precedence and associativity
                    val n = 2 + int(4)
                    (0 until n).joinToString("") { i -> (if (i > 0) pick(bin) else "") + expr(depth - 2) }
                }
                7 -> "(" + expr(depth - 1) + ")(" + pick(casts) + ")"
                8 -> { val (name, ps) = pick(fns); name + "(" + ps.joinToString(",") { expr(depth - 1) } + ")" }
                9 -> pick(listOf("y", "y_last", "x")) + pick(assigns) + expr(depth - 1)
                10 -> pick(listOf("y++", "y--", "++y_last", "--x", "x++"))
                11 -> "(" + expr(depth - 1) + "," + expr(depth - 1) + ")"
                else -> pick(vars) + "(" + pick(casts) + ")"
            }
        }

        fun text(): String = when (int(10)) {
            0 -> expr(2) + ");y=" + expr(2) + ";ToF64(" + expr(2)   // several statements
            else -> expr(4)
        }
    }

    @Test
    fun randomExpressionsAgainstTheInterpreter() {
        val n = System.getProperty("templeos.dynexpr.fuzz")?.toInt() ?: 3000
        val gen = Gen(20261020)
        val terry = ExeHarness(Engine.TERRY)
        val native = ExeHarness(Engine.NATIVE)
        val xs = doubleArrayOf(-45.0, -1.0, 0.0, 0.5, 7.0, 320.0)
        var ran = 0; var errors = 0; var raised = 0; var outside = 0; var mismatch = 0
        val report = StringBuilder()
        for (i in 0 until n) {
            val text = gen.text()
            val x = xs[i % xs.size]
            val a = terry.run(text, x); val b = native.run(text, x)
            when {
                isOutside(b[5]) -> { outside++; report.append("outside: [$text] ${b[5]}\n") }
                a != b -> { mismatch++; report.append("[$text] x=$x\n  terry =$a\n  native=$b\n") }
                isCompileError(a[5]) -> errors++
                a[5].startsWith("ex:") -> raised++
                else -> ran++
            }
        }
        assertEquals(0L, native.k.vm.instructionsExecuted)
        terry.close(); native.close()
        val summary = "fuzz: $n expressions: $ran evaluated alike, $errors compile errors alike, $raised exceptions alike, $outside outside the subset, $mismatch mismatches"
        File("build").mkdirs(); File("build/dynexpr-fuzz.txt").writeText(summary + "\n" + report)
        println(summary); print(report.toString().take(4000))
        assertEquals(report.toString().take(3000), 0, mismatch + outside)
    }

    // ------------------------------------------------------------ Cartesian on both engines

    /** The runs' checkpoints for the Swift harness (four engines: Swift tests compare with these when present). */
    private fun writeCheckpoints(id: String, a: Run, b: Run) {
        File("build/parity").mkdirs()
        File("build/parity/$id.terry.json").writeText(checkpointsJson(a.checkpoints))
        File("build/parity/$id.native.json").writeText(checkpointsJson(b.checkpoints))
    }

    private fun typed(ms0: Long, s: String): Pair<List<Ev>, Long> {
        val ev = ArrayList<Ev>()
        var ms = ms0
        for (c in s) { ev.addAll(Script.tap(ms, c)); ms += 100 }
        ev.addAll(Script.tap(ms, '\n'))
        return ev to ms + 100
    }

    private fun cartesianScript(formulas: List<String>, end: (Long) -> List<Ev>): Script {
        val ev = ArrayList<Ev>()
        var ms = 600L
        for (f in formulas) {
            val (e, m) = typed(ms, f); ev.addAll(e); ms = m + 1500
            ev.addAll(Script.tap(ms, ' ')); ms += 600
        }
        ev.addAll(end(ms))
        return Script("cartesian", ms + 1500, ev)
    }

    @Test
    fun cartesianRunsNativelyWithTypedFormulas() {
        val formulas = listOf("2*x", "Sin(x/20)*100", "x*x/100", "2*", "0<x<100 ^^ x`2/500>20")
        val s = cartesianScript(formulas) { ms -> Script.special(ms, Keys.SC_ESC) }
        val a = runScript(CARTESIAN, Engine.TERRY, s)
        val b = runScript(CARTESIAN, Engine.NATIVE, s)
        val d = compareRuns(a, b)
        writeCheckpoints("dynexpr.cartesian-formulas", a, b)
        val evals = b.kernel.dynExprEvaluations
        val compiles = b.kernel.dynExprCompiles
        val ins = b.kernel.vm.instructionsExecuted
        // the invalid formula's compile error, printed in red by every ExePrint of its graph (on both engines: compared above)
        val reported = a.checkpoints.count { it.console.contains("${DynExpr.FILE}:1: unexpected ')'") }
        a.kernel.terminate("done"); b.kernel.terminate("done")
        println("Cartesian: native ExePrint evaluations=$evals compiles=$compiles bytecode=$ins; terry frames=${a.checkpoints.last().frameCount} ticks=${a.checkpoints.last().ticks}")
        assertNull(d, d)
        assertEquals(0L, ins)
        // each formula is graphed over x = -h..h (one ExePrint per point; the invalid one is reported each time)
        assertTrue("evaluations: $evals", evals % formulas.size == 0L && evals / formulas.size > 600)
        assertEquals(formulas.size.toLong(), compiles)
        assertTrue("checkpoints showing the compile error: $reported", reported > 0)
    }

    @Test
    fun cartesianDivisionByZeroEndsTheProgramAlike() {
        val s = cartesianScript(listOf("1/0")) { emptyList() }
        val a = runScript(CARTESIAN, Engine.TERRY, s)
        val b = runScript(CARTESIAN, Engine.NATIVE, s)
        val d = compareRuns(a, b)
        writeCheckpoints("dynexpr.cartesian-divzero", a, b)
        val ca = a.checkpoints.last().console
        a.kernel.terminate("done"); b.kernel.terminate("done")
        println("Cartesian 1/0, console: ${ca.trim().replace("\n", " | ")}")
        assertNull(d, d)
        assertTrue(ca, ca.contains("DivZero"))
    }

    // ------------------------------------------------------------ timing (host JVM)

    @Test
    fun timings() {
        val native = ExeHarness(Engine.NATIVE)
        val terry = ExeHarness(Engine.TERRY)
        val k = native.k
        val formulas = listOf("2*x", "Sin(x/20)*100", "x*x*x*x/1000000-x*x/100", "Abs(Sin(x/30))*Exp(-Abs(x)/200)*150", "Sqr(x)/100")
        val scope = object : DynScope {
            override fun symbol(name: String) = k.prog.globals[name]
            override fun isClassName(name: String) = k.prog.classes.containsKey(name)
            override fun isKnownMacro(name: String) = false
        }
        val sb = StringBuilder("host JVM (-XX:-DontCompileHugeMethods): parse+check one text, evaluate it once (cached, through DynExprEngine.exePrint),\n" +
            "and graph it (641 ExePrint calls through the kernel's native, as Cartesian's loop; best of 10) natively and on the interpreter\n")
        sb.append("%-42s %12s %12s %14s %14s\n".format("formula", "parse+check", "evaluate", "graph native", "graph terry"))
        for (f in formulas) {
            val src = latin1("ToF64($f);")
            val policy = io.github.templeosmobile.core.dynexpr.DynGlobalPolicy { g -> g.name !in k.preludeGlobals }
            repeat(2000) { DynExpr.compile(src, scope, policy) }
            val n1 = 20000
            var t0 = System.nanoTime()
            repeat(n1) { DynExpr.compile(src, scope, policy) }
            val parseNs = (System.nanoTime() - t0) / n1
            // a graph: ExePrint for x = -320..320 through the kernel's native, as Cartesian calls it
            repeat(10) { native.graph(f); terry.graph(f) }
            val gn = (0 until 10).minOf { native.graph(f) }
            val gt = (0 until 10).minOf { terry.graph(f) }
            // evaluation alone (cached text), without the harness's bookkeeping
            val t = k.adamTask!!
            repeat(20000) { k.dynExpr.exePrint(t, src, false) }
            val n2 = 100000
            t0 = System.nanoTime()
            repeat(n2) { k.dynExpr.exePrint(t, src, false) }
            val evalNs = (System.nanoTime() - t0) / n2
            sb.append("%-42s %9.2f us %9.2f us %11.3f ms %11.3f ms\n".format(f.take(42), parseNs / 1000.0, evalNs / 1000.0, gn / 1e6, gt / 1e6))
        }
        native.close(); terry.close()
        File("build").mkdirs(); File("build/dynexpr-bench.txt").writeText(sb.toString())
        println(sb)
    }
}
