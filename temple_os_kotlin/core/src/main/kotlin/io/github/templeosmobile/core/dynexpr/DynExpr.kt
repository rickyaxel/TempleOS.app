package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.holyc.CompileError
import io.github.templeosmobile.core.holyc.FuncSym
import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.Program
import io.github.templeosmobile.core.holyc.Sym
import io.github.templeosmobile.core.holyc.Task
import io.github.templeosmobile.core.holyc.Vm
import io.github.templeosmobile.core.holyc.VmFault
import io.github.templeosmobile.core.holyc.VmKill
import io.github.templeosmobile.core.holyc.VmUncaught
import io.github.templeosmobile.core.kernel.Kernel

/**
 * Sandbox limits of the native dynamic expression engine (the same numbers in TempleCore/DynExpr).
 * Text beyond them is rejected with a compile error before anything runs (source length) or when the
 * parser reaches the limit (tokens, nesting); the evaluation budget cannot be reached by text within the
 * token limit (no loops, each node runs at most once per statement) and is a backstop.
 */
object DynLimits {
    /** Bytes of text (after ExePrint's formatting). */
    const val MAX_SOURCE_BYTES = 8192
    /** Tokens after macro expansion, all statements together. */
    const val MAX_TOKENS = 4096
    /** Height of a statement's tree (left-associative operator sequences count once: see [DFold]). */
    const val MAX_AST_HEIGHT = 256
    /** Sub-expressions being parsed inside one another (parentheses, unary operators, arguments, `` ` ``, `=`). */
    const val MAX_PARSE_NESTING = 1024
    /** Nodes evaluated per ExePrint call. */
    const val MAX_EVAL_OPS = 100_000
    /** The kernel's stop flag is polled every this many nodes, at every statement and every HolyC call. */
    const val CANCEL_CHECK_EVERY = 1024
    /** Parsed and checked texts kept per kernel (least recently used are dropped). */
    const val CACHE_ENTRIES = 32
}

/** A text compiled for one kernel: its chunks, and the symbol lookups the parse depended on. */
class DynCompiled internal constructor(
    val chunks: List<DChunk>,
    private val names: Array<String>, private val syms: Array<Sym?>,
    private val classNames: Array<String>, private val classFlags: BooleanArray,
) {
    /** True while every name still means what it meant when the text was parsed. */
    fun valid(prog: Program): Boolean {
        for (i in names.indices) if (prog.globals[names[i]] !== syms[i]) return false
        for (i in classNames.indices) if (prog.classes.containsKey(classNames[i]) != classFlags[i]) return false
        return true
    }
}

/**
 * Native, sandboxed evaluation of the HolyC that TempleOS programs compile at run time with
 * `ExePrint`/`ExePrint2` (Cartesian's formula, GetI64/GetF64's typed numbers), for kernels that run a
 * program as native code and have no HolyC compiler (Pure Kotlin mode).
 *
 * Pipeline: [DynLexer] → [DynParser] (typed AST, [DNode]) → [DynChecker] (subset, calls, frame) →
 * [DynEval] (tree walk). The text is a sequence of expression statements; each statement is a chunk that
 * runs before the next is compiled, as in TempleOS. ExePrint's value is the last statement's value.
 *
 * Supported: integer/char/float literals; TempleOS numeric constants ([DynMacros]); the running program's
 * scalar globals (read, `=`, compound assignment, `++`/`--`); every HolyC operator on scalars with the
 * compiler's precedence, associativity, typing, promotion and chaining rules; postfix casts to builtin
 * scalar types; comma expressions; `sizeof` of builtin types and of supported expressions; calls of the
 * pure math functions in [DynFunctions]. Everything else the compiler accepts (strings, pointers, `&`,
 * `*`, `[]`, members, other functions or globals, declarations, statements, directives, other macros) is a
 * compile error saying it is outside the native expression subset, which ExePrint reports and ExePrint2
 * throws exactly as a compile error.
 */
object DynExpr {
    /** The name the interpreter compiles ExePrint text under (NativesSys.runNested). */
    const val FILE = "C:/Home/ExePrint.HC"
    private const val OUTSIDE = "outside the native expression subset: "
    private const val LIMIT = "outside the native expression engine's limits: "

    fun outside(what: String, file: String, line: Int) = CompileError("$OUTSIDE$what; Pure Terry compiles it", file, line)
    fun limit(what: String, file: String, line: Int) = CompileError("$LIMIT$what", file, line)
    fun isOutside(e: CompileError) = e.bare.startsWith(OUTSIDE) || e.bare.startsWith(LIMIT)

    /** Lexes, parses and checks [src] against [scope] (no evaluation). */
    fun compile(src: ByteArray, scope: DynScope, policy: DynGlobalPolicy, file: String = FILE): List<DChunk> {
        if (src.size > DynLimits.MAX_SOURCE_BYTES)
            return listOf(DError(limit("longer than ${DynLimits.MAX_SOURCE_BYTES} bytes", file, 1), true))
        // SourceFile.parse: the text ends at a NUL; binary attachments follow
        val nul = src.indexOf(0.toByte())
        val text = if (nul < 0) src else src.copyOfRange(0, nul)
        val bins = if (nul < 0) emptyMap() else attachments(src, nul + 1)
        val parser = DynParser(DynLexer(text, bins, file), scope, file)
        val checker = DynChecker(file, policy)
        val chunks = ArrayList<DChunk>()
        while (true) {
            val c = try {
                val ch = parser.parseChunk() ?: break
                if (ch is DStmt) checker.check(ch)
                ch
            } catch (e: CompileError) { DError(e, isOutside(e)) }
            chunks.add(c)
            if (c is DError) break
        }
        return chunks
    }

    private fun attachments(raw: ByteArray, from: Int): Map<Int, ByteArray> {
        fun le32(p: Int) = (raw[p].toInt() and 0xFF) or ((raw[p + 1].toInt() and 0xFF) shl 8) or
            ((raw[p + 2].toInt() and 0xFF) shl 16) or ((raw[p + 3].toInt() and 0xFF) shl 24)
        val bins = HashMap<Int, ByteArray>()
        var p = from
        while (p + 16 <= raw.size) {
            val num = le32(p); val size = le32(p + 8)
            p += 16
            if (size < 0 || size > raw.size - p) break
            bins[num] = raw.copyOfRange(p, p + size)
            p += size
        }
        return bins
    }

    /** "Unhandled exception 'X' in WHERE: msg" -> WHERE (the format of Vm.raise and NativeRuntime). */
    internal fun whereOf(message: String?, chName: String): String? {
        val prefix = "Unhandled exception '$chName' in "
        if (message == null || !message.startsWith(prefix)) return null
        val rest = message.substring(prefix.length)
        var i = rest.indexOf(')')
        while (i >= 0) {
            if (i == rest.length - 1 || rest.startsWith(": ", i + 1)) return rest.substring(0, i + 1)
            i = rest.indexOf(')', i + 1)
        }
        return null
    }
}

/** Counters that show where ExePrint text was evaluated (provenance: visible in tests and the perf log). */
class DynExprStats {
    /** ExePrint/ExePrint2 calls served by the engine. */
    @JvmField var evaluations = 0L
    /** Texts lexed, parsed and checked (cache misses). */
    @JvmField var compiles = 0L
    @JvmField var cacheHits = 0L
    /** Statements evaluated. */
    @JvmField var statements = 0L
    /** Calls that ended in a compile error, and how many of those were outside the subset. */
    @JvmField var compileErrors = 0L
    @JvmField var outsideSubset = 0L
}

/** The engine of one kernel: its cache (globals resolve per kernel) and counters. */
class DynExprEngine(private val k: Kernel) {
    val stats = DynExprStats()

    private val cache = object : LinkedHashMap<String, DynCompiled>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, DynCompiled>?) = size > DynLimits.CACHE_ENTRIES
    }

    /** Drops every cached text (the kernel's program changed). */
    fun invalidate() = cache.clear()

    /** Compiles [src] for this kernel, or returns the cached result when its names still resolve alike. */
    fun compiled(src: ByteArray): DynCompiled {
        val key = DynText.latin1(src)
        cache[key]?.let { if (it.valid(k.prog)) { stats.cacheHits++; return it } }
        stats.compiles++
        val names = ArrayList<String>(); val syms = ArrayList<Sym?>()
        val classNames = ArrayList<String>(); val classFlags = ArrayList<Boolean>()
        val prelude = k.preludeGlobals
        val scope = object : DynScope {
            override fun symbol(name: String): Sym? = k.prog.globals[name].also { names.add(name); syms.add(it) }
            override fun isClassName(name: String): Boolean = k.prog.classes.containsKey(name).also { classNames.add(name); classFlags.add(it) }
            override fun isKnownMacro(name: String): Boolean = DynMacros.isKnownMacro(name) { k.env.runtimeFile(it) }
        }
        val chunks = DynExpr.compile(src, scope, { g -> g.name !in prelude && k.prog.globals[g.name] === g })
        val c = DynCompiled(chunks, names.toTypedArray(), syms.toTypedArray(), classNames.toTypedArray(), classFlags.toBooleanArray())
        cache[key] = c
        return c
    }

    /**
     * ExePrint (rethrow = false) and ExePrint2 (rethrow = true) in a native kernel, with the interpreter's
     * behaviour (NativesSys.runNested): statements run one after another; at the first compile error the
     * message is printed in red and ExePrint returns the last statement's value (0 if none ran) while
     * ExePrint2 throws it; a fault while evaluating propagates as the interpreter's nested run raises it.
     */
    fun exePrint(t: Task, src: ByteArray, rethrow: Boolean): Long {
        stats.evaluations++
        pointerBindings(src)?.let {return it}
        val c = compiled(src)
        var res = 0L
        val host = KernelHost(k, t)
        val eval = DynEval(host)
        for ((i, chunk) in c.chunks.withIndex()) {
            when (chunk) {
                is DError -> {
                    stats.compileErrors++
                    if (chunk.outsideSubset) stats.outsideSubset++
                    k.console.write("\$RED\$${chunk.error.message}\$FG\$\n")
                    if (rethrow) throw chunk.error
                    k.compileErrorCaught(t)
                    return res
                }
                is DEmpty -> res = 0L
                is DStmt -> res = runChunk(t, eval, host, chunk, i)
            }
        }
        return res
    }

    /** Runtime-selected implementations in original AI tables; bounds and function types are checked. */
    private fun pointerBindings(src:ByteArray):Long? {
        if(src.size>DynLimits.MAX_SOURCE_BYTES) return null
        val parts=String(src,Charsets.ISO_8859_1).split(';').filter {it.isNotBlank()}
        if(parts.isEmpty() || parts.size>128) return null
        val pattern=Regex("\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*\\[\\s*([0-9]+)\\s*]\\s*=\\s*&\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*")
        val matches=parts.map {pattern.matchEntire(it) ?: return null}
        var result=0L
        for(match in matches) {
            val g=k.prog.globals[match.groupValues[1]] as? GlobalSym ?: return null
            val arr=g.type as? io.github.templeosmobile.core.holyc.ArrType ?: return null
            if(g.name in k.preludeGlobals || arr.elem.size!=8) return null
            val ptr=arr.elem as? io.github.templeosmobile.core.holyc.PtrType
            val f=k.prog.globals[match.groupValues[3]] as? FuncSym ?: return null
            val fn=ptr?.target as? io.github.templeosmobile.core.holyc.FuncType
            if(fn!=null && fn.name!=f.type.name) throw CompileError("Function pointer type mismatch",DynExpr.FILE,1)
            val index=match.groupValues[2].toIntOrNull() ?: throw CompileError("Array index out of bounds",DynExpr.FILE,1)
            if(index !in 0 until arr.count) throw VmFault(io.github.templeosmobile.core.holyc.Arena.BAD_MEM,"Function pointer array index out of bounds")
            result=k.prog.funcPtr(f);k.mem.st8(k.mem.check(g.addr.toLong()+8L*index,8),result);stats.statements++
        }
        return result
    }

    /** One chunk, framed as the interpreter's call of the compiled chunk function (Vm.callFunction + enter). */
    private fun runChunk(t: Task, eval: DynEval, host: KernelHost, s: DStmt, index: Int): Long {
        if (k.vm.interrupt) throw VmKill("stopped")
        if (t.depth >= Task.MAX_DEPTH) throw VmFault(Vm.STK_OVER, "stack overflow (call depth)")
        val fp = (t.msp + 7) and 7.inv()
        if (fp + s.frameSize > t.mspLimit) throw VmFault(Vm.STK_OVER, "stack overflow")
        val savedMsp = t.msp; val savedDepth = t.depth; val savedNest = t.nestLevel
        host.fp = fp
        t.depth = savedDepth + 1; t.msp = fp + s.frameSize; t.nestLevel = savedNest + 1
        try {
            stats.statements++
            return eval.run(s)
        } catch (c: CalleeFault) {
            // a fault in a HolyC function the expression called: the interpreter's nested run reports it where it happened
            val u = c.u
            exceptCh(t, u.ch)
            throw VmFault(u.ch, u.message ?: "").also { it.where = DynExpr.whereOf(u.message, k.vm.chStr(u.ch)) ?: chunkWhere(index, eval.line) }
        } catch (f: VmFault) {
            // a fault in the expression itself (or a native it called): raised in the chunk, as Vm.raise words it
            exceptCh(t, f.ch)
            val where = chunkWhere(index, eval.line)
            val m = "Unhandled exception '${k.vm.chStr(f.ch)}' in $where" + (if (f.message.isNullOrEmpty()) "" else ": ${f.message}")
            throw VmFault(f.ch, m).also { it.where = where }
        } finally {
            t.msp = savedMsp; t.depth = savedDepth; t.nestLevel = savedNest
            t.blocked = false
        }
    }

    private fun chunkWhere(index: Int, line: Int) = "\$init:${DynExpr.FILE}#$index (${DynExpr.FILE}:$line)"

    private fun exceptCh(t: Task, ch: Long) {
        if (t.fsAddr != 0 && k.vm.exceptChOff >= 0) {
            k.mem.st8(t.fsAddr + k.vm.exceptChOff, ch)
            k.mem.st1(t.fsAddr + k.vm.catchExceptOff, 0)
        }
    }

    /** A fault that escaped a HolyC function the expression called (Vm.callFunction's VmUncaught). */
    private class CalleeFault(val u: VmUncaught) : RuntimeException(null, null, false, false)

    /** The kernel as evaluation sees it: arena memory, natives, HolyC calls, the stop flag. */
    private inner class KernelHost(private val k: Kernel, private val t: Task) : DynHost {
        var fp = 0
        override fun ld(addr: Int, size: Int): Long = when (size) {
            1 -> k.mem.ld1(addr); 2 -> k.mem.ld2(addr); 4 -> k.mem.ld4(addr); else -> k.mem.ld8(addr)
        }
        override fun st(addr: Int, size: Int, v: Long) = when (size) {
            1 -> k.mem.st1(addr, v); 2 -> k.mem.st2(addr, v); 4 -> k.mem.st4(addr, v); else -> k.mem.st8(addr, v)
        }
        override fun frameStore(off: Int, v: Long) = k.mem.st8(fp + off, v)
        override fun poll() { if (k.vm.interrupt || k.stopRequested) throw VmKill("stopped") }
        override fun call(fn: FuncSym, args: LongArray): Long {
            if (fn.isNative) {
                // CALLN
                val nf = k.vm.natives.list[fn.nativeIndex]
                val base = t.sp
                for (i in args.indices) t.st[base + i] = args[i]
                t.sp = base + args.size
                t.blocked = false
                try {
                    val r = nf.call(t, base, args.size)
                    t.resumed = false
                    return r
                } finally { t.sp = base; t.blocked = false }
            }
            // CALL: one budget tick, then the function (its own ticks are counted by the call)
            k.vm.ticksExecuted++
            if (k.vm.interrupt) throw VmKill("stopped")
            try {
                return k.vm.callFunction(t, k.prog.funcPtr(fn), *args)
            } catch (u: VmUncaught) { throw CalleeFault(u) }
        }
    }
}
