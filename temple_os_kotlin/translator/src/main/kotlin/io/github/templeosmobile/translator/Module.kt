package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import java.util.IdentityHashMap

/** An address field of a generated module: a global, a string or a binary literal, set when [unit] loads. */
class Field(val name: String, val buildAddr: Int, val unit: Int, val comment: String)

/**
 * One generated module: the prelude, or one program (its chunks). Holds what both printers need:
 * the lowered functions, the address fields with the data-segment unit that defines them, the
 * natives the code calls, and the dispatch table.
 */
class ModuleModel(
    val className: String,
    val isPrelude: Boolean,
    /** Source description for the header comment. */
    val source: String,
    val sourceHash: String,
) {
    val functions = ArrayList<IrFunction>()
    val fields = ArrayList<Field>()
    val natives = sortedSetOf<String>()
    val diagnostics = ArrayList<String>()
}

/**
 * Builds a [ModuleModel] from captured units: assigns field names to every global, string and
 * binary literal the module's functions use (prelude ones are reached as `P.name` from a program),
 * and lowers every function.
 */
class ModuleBuilder(
    private val model: ModuleModel,
    /** This module's units (prelude: one; program: its chunks), in load order. */
    private val units: List<CapturedUnit>,
    /** The prelude module's builder when building a program (for `P.` references). */
    private val prelude: ModuleBuilder?,
    /** Where the code generator placed each binary literal node. */
    private val binNodes: Map<Expr, Int> = emptyMap(),
) : ModuleCtx {
    private val globalField = HashMap<Int, String>()          // build addr -> field
    private val stringField = HashMap<String, String>()       // latin1 -> field
    private val binField = HashMap<Int, String>()            // build addr -> field
    private val usedNames = HashSet<String>()
    /** Functions defined (compiled) in this module, by index. */
    val defined = HashMap<Int, CapturedFunction>()
    private val fnRefs = HashMap<Int, FnRef>()

    // where each data item is first allocated among this module's units
    private val globalUnit = HashMap<Int, Pair<Int, Int>>()  // addr -> (unit, size)
    private val stringUnit = HashMap<String, Pair<Int, Int>>() // latin1 -> (unit, addr)
    private val binUnit = HashMap<Int, Int>()                 // build addr -> unit

    init {
        for ((ui, u) in units.withIndex()) {
            for (ev in u.events) when (ev) {
                is SegEvent.Global -> globalUnit.putIfAbsent(ev.addr, ui to ev.size)
                is SegEvent.Str -> stringUnit.putIfAbsent(latin1(ev.bytes), ui to ev.addr)
                is SegEvent.Bin -> binUnit.putIfAbsent(ev.addr, ui)
                is SegEvent.Const -> {}
            }
            for (cf in u.functions) defined[cf.f.index] = cf
        }
    }

    /**
     * The prelude declares a field for every named global it allocates, whether or not prelude code uses
     * it: programs reach them as `P.name`, and the prelude module must not depend on which programs are
     * translated (incremental runs regenerate it alone).
     */
    fun declareAllGlobals(globals: Map<String, Sym>) {
        val byAddr = HashMap<Int, GlobalSym>()
        for ((_, s) in globals.entries.sortedBy { it.key }) if (s is GlobalSym) byAddr.putIfAbsent(s.addr, s)
        for (u in units) for (ev in u.events) if (ev is SegEvent.Global) byAddr[ev.addr]?.let { global(it) }
    }

    private fun unique(base: String): String {
        var n = base
        var i = 2
        while (!usedNames.add(n)) n = "${base}_${i++}"
        return n
    }

    @Synchronized
    override fun global(sym: GlobalSym): String {
        globalField[sym.addr]?.let { return it }
        val u = globalUnit[sym.addr]
        if (u == null) {
            val p = prelude ?: throw TranslateError("global ${sym.name} has no storage in this module", "", 0)
            return "P." + p.global(sym)
        }
        val name = unique("g_" + Lowerer.ident(sym.name))
        globalField[sym.addr] = name
        model.fields.add(Field(name, sym.addr, u.first, "${sym.name}: ${sym.type.name}"))
        return name
    }

    @Synchronized
    override fun string(bytes: ByteArray): String {
        val key = latin1(bytes)
        stringField[key]?.let { return it }
        val u = stringUnit[key] ?: run {
            val p = prelude ?: throw TranslateError("string literal \"${preview(key)}\" was not interned", "", 0)
            return "P." + p.string(bytes)
        }
        val name = unique("s${stringField.size}")
        stringField[key] = name
        model.fields.add(Field(name, u.second, u.first, "\"${preview(key)}\""))
        return name
    }

    @Synchronized
    override fun bin(e: BinLit): String {
        val addr = binNodes[e] ?: throw TranslateError("binary literal (${e.bytes.size} bytes) was not placed", e.file, e.line)
        binField[addr]?.let { return it }
        val u = binUnit[addr] ?: throw TranslateError("binary literal at 0x${Integer.toHexString(addr)} is not in this module's data", e.file, e.line)
        val name = unique("b${binField.size}")
        binField[addr] = name
        model.fields.add(Field(name, addr, u, "binary literal, ${e.bytes.size} bytes"))
        return name
    }

    @Synchronized
    override fun fn(f: FuncSym): FnRef? {
        fnRefs[f.index]?.let { return it }
        val own = defined[f.index]
        if (own != null) {
            val r = refOf(own.f, model.className, "")
            fnRefs[f.index] = r
            return r
        }
        val p = prelude ?: return null
        val r = p.fn(f) ?: return null
        return FnRef(r.index, r.module, "P." + r.name, r.params, r.ret, r.varargs)
    }

    fun lowerAll() {
        for (cf in defined.values.sortedBy { it.f.index }) {
            val ref = fn(cf.f)!!
            try {
                model.functions.add(Lowerer(this, cf, ref).lower())
            } catch (e: TranslateError) {
                model.diagnostics.add("${e.message} (in ${cf.f.name})")
            }
        }
        // natives used
        for (fn in model.functions) collectNatives(fn.body)
    }

    private fun collectNatives(list: List<S>) {
        for (s in list) {
            when (s) {
                is SCall -> if (s.callee is CNative && s.callee.index >= 0) model.natives.add(s.callee.name)
                is SIf -> { collectNatives(s.t); s.f?.let { collectNatives(it) } }
                is SLoop -> { collectNatives(s.pre); collectNatives(s.body); collectNatives(s.post) }
                is SBlock -> collectNatives(s.body)
                is SRetryLoop -> collectNatives(s.body)
                is STry -> { collectNatives(s.body); collectNatives(s.handler) }
                is SWhen -> { s.arms.forEach { collectNatives(it.body) }; s.dflt?.let { collectNatives(it) } }
                is SMachine -> s.blocks.forEach { collectNatives(it.body) }
                else -> {}
            }
            forEachX(s) { x -> natPtrs(x) }
        }
    }

    private fun natPtrs(x: X) {
        when (x) {
            is XNatPtr -> model.natives.add(x.name)
            is XOp -> { natPtrs(x.a); x.b?.let { natPtrs(it) } }
            is XLoad -> natPtrs(x.a)
            is XLoadF -> natPtrs(x.a)
            else -> {}
        }
    }

    companion object {
        fun refOf(f: FuncSym, module: String, prefix: String): FnRef {
            val ft = f.ftype
            val ret: K? = when (ft.ret) { is VoidType -> null; is F64Type -> K.F; else -> K.I }
            return FnRef(f.index, module, prefix + "f${f.index}_${Lowerer.ident(f.name.removePrefix("\$"))}",
                ft.params.map { if (it.type is F64Type) K.F else K.I }, ret, ft.varargs)
        }

        fun preview(s: String): String {
            val sb = StringBuilder()
            for (c in s.take(40)) sb.append(if (c.code in 32..126 && c != '"' && c != '\\' && c != '*' && c != '/') c else '.')
            if (s.length > 40) sb.append("...")
            return sb.toString()
        }
    }
}

/** Calls [fn] on every expression directly held by statement [s] (not nested statements). */
fun forEachX(s: S, fn: (X) -> Unit) {
    when (s) {
        is SDecl -> s.init?.let(fn)
        is SSet -> fn(s.x)
        is SStore -> { fn(s.a); fn(s.x) }
        is SEval -> fn(s.x)
        is SCopy -> { fn(s.dst); fn(s.src) }
        is SCall -> { (s.callee as? CPtr)?.let { fn(it.fp) }; s.args.forEach(fn); s.extra.forEach(fn) }
        is SIf -> fn(s.c)
        is SLoop -> s.cond?.let(fn)
        is SReturn -> s.x?.let(fn)
        is SWhen -> fn(s.x)
        else -> {}
    }
}
