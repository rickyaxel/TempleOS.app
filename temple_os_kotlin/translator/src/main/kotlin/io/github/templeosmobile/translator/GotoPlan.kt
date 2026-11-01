package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import java.util.IdentityHashMap

/**
 * How a function's gotos are lowered.
 *
 * A goto whose label sits in a statement list that encloses the goto becomes structured code: a
 * forward goto leaves a labeled block that ends at the label; a backward goto continues a loop that
 * starts at the label (charging the budget tick of the VM's backward jump). The blocks and loops of
 * one list must nest; when they cannot, or a goto jumps into a nested statement (another branch,
 * another case), the whole function uses the dispatch-loop fallback ([unstructured]).
 *
 * The VM decides "backward" by code addresses; [backward] uses the same order: CodeGen's emission
 * order (a for loop's step after its body, a do-while's test after its body).
 */
class GotoPlan(body: Stmt) {
    class Range(val start: Int, val end: Int, val label: String, val backward: Boolean)

    private class LabelInfo(val list: List<Stmt>, val index: Int, val seq: Int)
    private class GotoInfo(val stmt: Goto, val path: List<Pair<List<Stmt>, Int>>, val seq: Int)

    private val labels = HashMap<String, LabelInfo>()
    private val gotos = ArrayList<GotoInfo>()
    private val gotoSeq = IdentityHashMap<Goto, Int>()
    private val labelTryDepth = HashMap<String, Int>()
    private val ranges = IdentityHashMap<List<Stmt>, List<Range>>()
    private val withLabels = IdentityHashMap<Stmt, Boolean>()
    private val gotoNamesIn = IdentityHashMap<Stmt, Set<String>>()
    var unstructured = false
        private set
    private var seq = 0
    private var duplicate = false

    val labelNames: Set<String> get() = labels.keys

    init {
        walk(body, ArrayList(), 0)
        if (gotos.isNotEmpty()) plan()
    }

    fun rangesFor(list: List<Stmt>): List<Range> = ranges[list] ?: emptyList()
    fun containsLabel(s: Stmt): Boolean = withLabels[s] == true
    fun gotoNames(s: Stmt): Set<String> = gotoNamesIn[s] ?: emptySet()
    fun tryDepthOf(label: String): Int = labelTryDepth[label] ?: 0

    /** True when [g] jumps backward in the VM's code layout (it then charges a budget tick). */
    fun backward(g: Goto): Boolean {
        val l = labels[g.label] ?: return false
        return l.seq <= (gotoSeq[g] ?: Int.MAX_VALUE)
    }

    private fun walk(s: Stmt, path: ArrayList<Pair<List<Stmt>, Int>>, tryDepth: Int): Pair<Boolean, Set<String>> {
        var hasLabel = false
        val names = HashSet<String>()
        fun sub(x: Stmt?, d: Int = tryDepth) { if (x != null) { val (l, n) = walk(x, path, d); hasLabel = hasLabel || l; names.addAll(n) } }
        fun list(xs: List<Stmt>) {
            for ((i, x) in xs.withIndex()) {
                path.add(xs to i)
                if (x is Label) {
                    if (labels.containsKey(x.name)) duplicate = true
                    labels[x.name] = LabelInfo(xs, i, seq++)
                    labelTryDepth[x.name] = tryDepth
                    hasLabel = true
                }
                sub(x)
                path.removeAt(path.size - 1)
            }
        }
        when (s) {
            is Block -> list(s.list)
            is If -> { seq++; sub(s.t); sub(s.f) }
            is While -> { seq++; sub(s.body) }
            is DoWhile -> { sub(s.body); seq++ }
            is For -> { sub(s.init); seq++; sub(s.body); seq++ }
            is Switch -> { seq++; list(s.body) }
            is Try -> { sub(s.body, tryDepth + 1); sub(s.handler) }
            is Goto -> { val n = seq++; gotos.add(GotoInfo(s, ArrayList(path), n)); gotoSeq[s] = n; names.add(s.label) }
            is Label -> {
                // a label that is not directly in a list (the body of an if): only the fallback handles it
                if (path.isEmpty() || path.last().first.getOrNull(path.last().second) !== s) {
                    if (!labels.containsKey(s.name)) labels[s.name] = LabelInfo(emptyList(), -1, seq++) else duplicate = true
                    labelTryDepth[s.name] = tryDepth
                }
                hasLabel = true
            }
            else -> seq++
        }
        withLabels[s] = hasLabel
        gotoNamesIn[s] = names
        return hasLabel to names
    }

    private fun plan() {
        if (duplicate) { unstructured = true; return }
        val byList = IdentityHashMap<List<Stmt>, ArrayList<Range>>()
        val fwdStart = HashMap<String, Int>()
        val backEnd = HashMap<String, Int>()
        for (g in gotos) {
            val l = labels[g.stmt.label] ?: throw TranslateError("undefined label '${g.stmt.label}'", g.stmt.file, g.stmt.line)
            if (l.index < 0) { unstructured = true; return }
            // labels inside a switch body are entry points among case labels: fallback
            val at = g.path.firstOrNull { it.first === l.list } ?: run { unstructured = true; return }
            val j = at.second
            if (j < l.index) fwdStart[g.stmt.label] = minOf(fwdStart[g.stmt.label] ?: j, j)
            else backEnd[g.stmt.label] = maxOf(backEnd[g.stmt.label] ?: j, j)
        }
        for ((name, s) in fwdStart) { val l = labels[name]!!; byList.getOrPut(l.list) { ArrayList() }.add(Range(s, l.index, name, false)) }
        for ((name, e) in backEnd) { val l = labels[name]!!; byList.getOrPut(l.list) { ArrayList() }.add(Range(l.index, e + 1, name, true)) }
        for ((list, rs0) in byList) {
            // forward blocks that overlap start together (they then nest by their ends)
            var rs = rs0.toList()
            var changed = true
            while (changed) {
                changed = false
                val fw = rs.filter { !it.backward }
                val out = ArrayList<Range>()
                for (b in rs) {
                    if (b.backward) { out.add(b); continue }
                    var start = b.start
                    for (a in fw) if (a !== b && a.end < b.end && a.start < start && start < a.end) start = a.start
                    if (start != b.start) changed = true
                    out.add(Range(start, b.end, b.label, false))
                }
                rs = out
            }
            for (a in rs) for (b in rs) {
                if (a === b) continue
                val disjoint = a.end <= b.start || b.end <= a.start
                val nested = (a.start <= b.start && b.end <= a.end) || (b.start <= a.start && a.end <= b.end)
                if (!disjoint && !nested) { unstructured = true; return }
            }
            if (byList.keys.any { it !== list && isSwitchBody(it) } || isSwitchBody(list)) { unstructured = true; return }
            ranges[list] = rs
        }
    }

    private val switchBodies = IdentityHashMap<List<Stmt>, Boolean>()
    private fun isSwitchBody(l: List<Stmt>) = l.any { it is CaseLabel || it is SubStart || it is SubEnd }
}
