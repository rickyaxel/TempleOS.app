package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import java.io.File

/** Counts the HolyC constructs the translator has to lower, per source and in total. */
class ConstructStats {
    val counts = sortedMapOf<String, Int>()
    fun add(k: String, n: Int = 1) { counts[k] = (counts[k] ?: 0) + n }

    fun function(cf: CapturedFunction) {
        val f = cf.f
        add("functions")
        if (f.ftype.varargs) add("varargs functions")
        if (f.ftype.ret is F64Type) add("F64-returning functions")
        val addressed = HashSet<Sym>()
        object : AstWalk() {
            override fun stmt(s: Stmt) {
                when (s) {
                    is Goto -> add("goto")
                    is Label -> add("labels")
                    is Try -> add("try/catch")
                    is Switch -> {
                        add("switch")
                        if (s.body.any { it is SubStart }) add("switch start:/end: groups")
                        if (fallsThrough(s)) add("switch with fallthrough")
                    }
                    is DoWhile -> add("do-while")
                    is For -> add("for")
                    is While -> add("while")
                    else -> {}
                }
                super.stmt(s)
            }

            override fun expr(e: Expr) {
                when (e) {
                    is AddrOf -> { add("address-of"); rootSym(e.e)?.let { addressed.add(it) } }
                    is Call -> {
                        if (e.fn == null) add("indirect calls")
                        else if (e.fn!!.isNative) add("native calls") else add("direct calls")
                        if (e.args.any { it == null } || e.args.size < e.ftype.params.size) add("calls using default args")
                    }
                    is Chain -> add("chained comparisons")
                    is Comma -> add("comma expressions")
                    is Logical -> add("logical ${e.op}")
                    is Cast -> add("casts")
                    is StrLit -> add("string literals")
                    is BinLit -> add("binary literals")
                    is FuncAddr -> add("function addresses")
                    else -> {}
                }
                super.expr(e)
            }
        }.stmt(cf.body)
        val loc = addressed.filterIsInstance<LocalSym>()
        if (loc.isNotEmpty()) add("functions with address-taken locals")
    }

    companion object {
        fun rootSym(e: Expr): Sym? = when (e) {
            is VarRef -> e.sym
            is MemberAccess -> if (e.viaPtr) null else rootSym(e.base)
            is Index -> if (e.base.type is ArrType) rootSym(e.base) else null
            is Cast -> rootSym(e.e)
            is Comma -> rootSym(e.xs.last())
            else -> null
        }

        /** True when control can fall from a non-empty case body into the next case label. */
        fun fallsThrough(s: Switch): Boolean {
            var lastWasJump = true
            var bodySinceLabel = false
            for (st in s.body) {
                when (st) {
                    is CaseLabel -> { if (bodySinceLabel && !lastWasJump) return true; bodySinceLabel = false }
                    is SubStart, is SubEnd -> {}
                    else -> { bodySinceLabel = true; lastWasJump = st is Break || st is Return || st is Continue || st is Goto }
                }
            }
            return false
        }
    }
}

fun stats(repo: Repo, out: File?) {
    val fs = Capture.fs(repo)
    val files = repo.bundledIndex.readLines().map { it.split('\t') }.filter { it.size > 2 && it[0] == "F" && it[1].uppercase().endsWith(".HC") }.map { "C:/" + it[1] }
    val report = StringBuilder()
    val total = ConstructStats()
    val pre = Capture.program(repo, fs, null)
    val preStats = ConstructStats()
    pre.prelude.functions.forEach { preStats.function(it) }
    report.append("== prelude (${pre.prelude.functions.size} functions, ${pre.prelude.events.size} data events)\n")
    preStats.counts.forEach { (k, v) -> report.append("   %-40s %d\n".format(k, v)) }
    var ok = 0; var failed = 0
    val failures = StringBuilder()
    for (path in files) {
        val cap = Capture.program(repo, fs, path)
        if (cap.error != null) { failed++; failures.append("%-50s %s\n".format(path, cap.error.take(160))); continue }
        ok++
        val st = ConstructStats()
        cap.chunks.forEach { u -> u.functions.forEach { st.function(it); total.function(it) } }
        val notes = cap.chunks.flatMap { it.notes }
        report.append("%-50s chunks=%d fns=%d %s %s\n".format(path, cap.chunks.size, cap.chunks.sumOf { it.functions.size },
            st.counts.filterKeys { it in setOf("goto", "try/catch", "switch with fallthrough", "switch start:/end: groups", "varargs functions", "indirect calls") }.toString(), notes.joinToString()))
    }
    report.append("\n== all programs: $ok compiled, $failed failed\n")
    total.counts.forEach { (k, v) -> report.append("   %-40s %d\n".format(k, v)) }
    report.append("\n== compile failures\n").append(failures)
    if (out != null) { out.parentFile?.mkdirs(); out.writeText(report.toString()) }
    println(report)
}
