package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import java.util.IdentityHashMap

/** A construct the translator cannot lower faithfully; reported with its source position. */
class TranslateError(msg: String, val file: String, val line: Int) : Exception("$file:$line: $msg")

/** What a function's lowering needs to know about the module it is generated into. */
interface ModuleCtx {
    /** The generated function for [f] (null: never defined, a call raises 'BadCall' as in the VM). */
    fun fn(f: FuncSym): FnRef?
    /** Field holding the address of the global whose storage starts at build address [addr]. */
    fun global(sym: GlobalSym): String
    fun string(bytes: ByteArray): String
    fun bin(e: BinLit): String
}

/**
 * Lowers one compiled HolyC function (typed AST, as the VM's [CodeGen] receives it) to [IrFunction].
 *
 * The rules mirror CodeGen operation by operation: every HolyC value is a 64-bit word (F64 as its
 * IEEE bits), loads sign/zero-extend from the storage width, stores truncate, `(F64)`/`(I64)` casts
 * reinterpret bits, comparisons are unsigned when either operand is unsigned, operands are evaluated
 * left to right (a target's address before the value, except when the target has side effects),
 * chained comparisons evaluate each operand once, and the VM's budget is charged on every backward
 * branch and every call of a HolyC function. Locals live in native variables unless the program
 * takes their address or they are aggregates; those live in an arena frame laid out exactly as the
 * VM's.
 */
class Lowerer(private val ctx: ModuleCtx, private val cf: CapturedFunction, private val ref: FnRef) {
    private val f = cf.f
    private val ftype = f.ftype

    // ---------------------------------------------------------------- analysis

    /** Locals and parameters by frame offset (parameters are recognised by their offsets). */
    private val paramIndexByOff = HashMap<Int, Int>().also { m -> f.paramOffsets.forEachIndexed { i, off -> m[off] = i } }
    private val memSyms: Set<LocalSym>
    private val regVars = IdentityHashMap<LocalSym, Var>()
    private val params = ArrayList<Var>()
    private val paramSpills = ArrayList<Pair<Int, Int>>()
    private val locals = ArrayList<Var>()
    private var argcVar: Var? = null
    private var argvVar: Var? = null

    init {
        val mem = HashSet<LocalSym>()
        val seen = HashSet<LocalSym>()
        object : AstWalk() {
            override fun stmt(s: Stmt) {
                if (s is LocalInit) { seen.add(s.sym); if (isAggregate(s.sym.type)) mem.add(s.sym) }
                super.stmt(s)
            }
            override fun expr(e: Expr) {
                when (e) {
                    is VarRef -> (e.sym as? LocalSym)?.let { seen.add(it); if (isAggregate(it.type)) mem.add(it) }
                    is AddrOf -> addrRoot(e.e)?.let { mem.add(it) }
                    is MemberAccess -> if (!e.viaPtr) addrRoot(e.base)?.let { mem.add(it) }
                    // `p(I64 *)++`: a local assigned through a cast keeps its register only when the
                    // cast type has the variable's width and kind (else the VM's partial store needs memory)
                    is Assign -> castMem(e.target)?.let { mem.add(it) }
                    is IncDec -> castMem(e.target)?.let { mem.add(it) }
                    else -> {}
                }
                super.expr(e)
            }
        }.stmt(cf.body)
        memSyms = mem
        // parameters: typed native parameters; spilled to the frame when used through memory
        for ((i, p) in ftype.params.withIndex()) {
            val v = Var("p${i}_${ident(p.name.ifEmpty { "arg" })}", kindOf(p.type), true)
            params.add(v)
        }
        for (s in seen) {
            val pi = paramIndexByOff[s.offset]
            if (pi != null && ftype.params[pi].name == s.name) {
                if (s in memSyms) paramSpills.add(pi to s.offset) else regVars[s] = params[pi]
                continue
            }
            if (ftype.varargs && s.offset == f.argcSlot && s.name == "argc") {
                val v = Var("argc", K.I, true); argcVar = v; if (s !in memSyms) regVars[s] = v; continue
            }
            if (ftype.varargs && s.offset == f.argvSlot && s.name == "argv") {
                val v = Var("argv", K.I, true); argvVar = v; if (s !in memSyms) regVars[s] = v; continue
            }
            if (s in memSyms) continue
            val v = Var("l${s.offset}_${ident(s.name)}", kindOf(s.type), true)
            regVars[s] = v
            locals.add(v)
        }
        locals.sortBy { it.name }
        paramSpills.sortBy { it.first }
    }

    private val needFrame = memSyms.isNotEmpty() || ftype.varargs

    /** The local behind a cast lvalue that cannot stay in a register (width or kind differ). */
    private fun castMem(target: Expr): LocalSym? {
        if (target !is Cast) return null
        var x: Expr = target
        while (x is Cast) x = x.e
        val l = (x as? VarRef)?.sym as? LocalSym ?: return addrRoot(x)
        val t = target.type
        return if (t.size != l.type.size || (t is F64Type) != (l.type is F64Type) || isAggregate(t)) l else null
    }

    private fun addrRoot(e: Expr): LocalSym? = when (e) {
        is VarRef -> e.sym as? LocalSym
        is MemberAccess -> if (e.viaPtr) null else addrRoot(e.base)
        is Cast -> addrRoot(e.e)
        is Comma -> addrRoot(e.xs.last())
        else -> null
    }

    // ---------------------------------------------------------------- output state

    private var cur = ArrayList<S>()
    private var tmpN = 0
    private var labelN = 0
    private var curPos: Pos? = null

    private fun emit(s: S) { s.pos = curPos; cur.add(s) }
    private fun temp(k: K): Var = Var("t${tmpN++}", k, false)
    private fun mutTemp(k: K): Var = Var("r${tmpN++}", k, true)
    private fun label(base: String): String = "${base}${labelN++}"

    private inline fun into(list: ArrayList<S>, block: () -> Unit): ArrayList<S> {
        val saved = cur; cur = list
        try { block() } finally { cur = saved }
        return list
    }

    /** Lowers an expression with its statements going to [list]. */
    private inline fun intoX(list: ArrayList<S>, block: () -> X): X {
        val saved = cur; cur = list
        try { return block() } finally { cur = saved }
    }

    private fun err(msg: String, e: Expr): Nothing = throw TranslateError(msg, e.file, e.line)
    private fun err(msg: String, s: Stmt): Nothing = throw TranslateError(msg, s.file, s.line)

    // ---------------------------------------------------------------- types

    private fun isAggregate(t: Type) = t is ArrType || (t is ClassType && t.valueType == null) || t is FuncType
    private fun kindOf(t: Type): K = if (t is F64Type) K.F else K.I

    private fun word(x: X): X = when (x.k) { K.I -> x; K.F -> XOp(Op.F2BITS, x); K.B -> XOp(Op.B2I, x) }
    private fun asI(x: X): X = if (x.k == K.B) XOp(Op.B2I, x) else x
    private fun truth(x: X): X = when (x.k) {
        K.B -> x
        K.I -> if (x is XOp && x.op == Op.B2I) x.a else XOp(Op.I2B, x)
        K.F -> XOp(Op.F2B, x)
    }

    /** CodeGen.convert: arithmetic conversion between F64 and integers (no truncation). */
    private fun convert(x0: X, from: Type, to: Type, at: Expr): X {
        val x = asI(x0)
        if (to is F64Type && from !is F64Type) {
            if (isAggregate(from)) err("cannot convert ${from.name} to F64", at)
            return XOp(if (Types.isUnsigned64(from) && from !is PtrType) Op.U2F else Op.I2F, x)
        }
        if (from is F64Type && to !is F64Type && !isAggregate(to)) return XOp(Op.F2I, x)
        // F64 to an aggregate keeps the raw bits; everything else is unchanged
        return if (to is F64Type) x else word(x)
    }

    /** CodeGen.narrow: truncates/extends a word to the storage width of [t]. */
    private fun narrow(x: X, t: Type): X {
        val it = Types.asInt(t) ?: return x
        return when (it.size) {
            1 -> XOp(if (it.signed) Op.SX1 else Op.ZX1, x)
            2 -> XOp(if (it.signed) Op.SX2 else Op.ZX2, x)
            4 -> XOp(if (it.signed) Op.SX4 else Op.ZX4, x)
            else -> x
        }
    }

    /** CodeGen.castValue: postfix casts reinterpret bits between F64 and integers. */
    private fun castValue(x0: X, from: Type, to: Type): X {
        val x = asI(x0)
        if (to is F64Type) return if (from is F64Type) x else XOp(Op.BITS2F, word(x))
        if (from is F64Type) return narrow(XOp(Op.F2BITS, x), to)
        return narrow(word(x), to)
    }

    private fun loadT(a: X, t: Type): X {
        if (t is F64Type) return XLoadF(a)
        val it = Types.asInt(t)
        if (it != null) return XLoad(it.size, it.signed && it.size < 8, a)
        return XLoad(8, false, a)
    }

    private fun widthOf(t: Type) = Types.asInt(t)?.size ?: 8

    private fun storeT(a: X, x: X, t: Type) = emit(SStore(widthOf(t), a, word(x)))

    // ---------------------------------------------------------------- ordering

    /** True when later statements cannot change the value of [x] (constants, temporaries, addresses). */
    private fun stable(x: X): Boolean = when (x) {
        is XI, is XF, is XB, is XStr, is XBin, is XGlob, is XFp, is XNatPtr -> true
        is XVar -> !x.v.mutable
        is XOp -> stable(x.a) && (x.b == null || stable(x.b))
        is XLoad, is XLoadF -> false
    }

    /** Register variables [list] assigns, and whether it can write arena memory (stores, copies, calls). */
    private fun effects(list: List<S>, sets: HashSet<Var>, mem: BooleanArray) {
        for (s in list) when (s) {
            is SDecl -> {}
            is SSet -> sets.add(s.v)
            is SStore, is SCopy, is SCall -> mem[0] = true
            is SIf -> { effects(s.t, sets, mem); s.f?.let { effects(it, sets, mem) } }
            is SLoop -> { effects(s.pre, sets, mem); effects(s.body, sets, mem); effects(s.post, sets, mem); mem[0] = true }
            is SBlock -> effects(s.body, sets, mem)
            is SRetryLoop -> effects(s.body, sets, mem)
            is STry -> { effects(s.body, sets, mem); effects(s.handler, sets, mem); mem[0] = true }
            is SWhen -> { s.arms.forEach { effects(it.body, sets, mem) }; s.dflt?.let { effects(it, sets, mem) } }
            else -> mem[0] = true // anything else: assume the worst
        }
    }

    /** Whether the value of [x] can differ after statements that assign [sets] (and write memory if [mem]). */
    private fun changedBy(x: X, sets: Set<Var>, mem: Boolean): Boolean = when (x) {
        is XVar -> x.v in sets
        is XLoad -> mem || changedBy(x.a, sets, mem)
        is XLoadF -> mem || changedBy(x.a, sets, mem)
        is XOp -> changedBy(x.a, sets, mem) || (x.b != null && changedBy(x.b, sets, mem))
        else -> false
    }

    private fun trivial(x: X): Boolean = x is XI || x is XF || x is XB || x is XStr || x is XBin || x is XGlob || x is XFp || x is XNatPtr || x is XVar

    private fun materialize(x: X): X {
        if (stable(x) && trivial(x)) return x
        val v = temp(x.k)
        emit(SDecl(v, x))
        return XVar(v)
    }

    /**
     * Evaluates operands left to right. When an operand needs statements (a call, an assignment),
     * every earlier operand whose value those statements could change is captured first, so each
     * operand sees the state at its own turn, as on the VM's operand stack.
     */
    private fun operands(vararg fs: () -> X): List<X> {
        val res = ArrayList<X>(fs.size)
        for (fn in fs) {
            val mark = cur.size
            val x = fn()
            if (cur.size > mark) {
                // what the new statements can change: the register variables they assign, and memory
                val sets = HashSet<Var>()
                val mem = booleanArrayOf(false)
                effects(cur.subList(mark, cur.size), sets, mem)
                val caps = ArrayList<S>()
                for (i in res.indices) {
                    if (!stable(res[i]) && changedBy(res[i], sets, mem[0])) {
                        val v = temp(res[i].k)
                        caps.add(SDecl(v, res[i]).also { it.pos = curPos })
                        res[i] = XVar(v)
                    }
                }
                if (caps.isNotEmpty()) cur.addAll(mark, caps)
            }
            res.add(x)
        }
        return res
    }

    // ---------------------------------------------------------------- expressions

    private fun at(e: Expr) { if (e.line > 0) curPos = Pos(e.file, e.line) }

    /** The value of [e] as the VM pushes it: K.F for F64 expressions, K.I otherwise. */
    fun value(e: Expr): X = asI(valueRaw(e))

    /** Like [value], but comparisons and logical operators may stay booleans (conditions). */
    private fun valueRaw(e: Expr): X {
        at(e)
        return when (e) {
            is IntLit -> XI(e.v)
            is FloatLit -> XF(e.v.toRawBits())
            is StrLit -> XStr(ctx.string(e.bytes))
            is BinLit -> XBin(ctx.bin(e))
            is FuncAddr -> funcPtr(e.fn)
            is VarRef -> loadVar(e)
            is Index, is Deref, is MemberAccess -> if (isAggregate(e.type)) addr(e) else loadT(addr(e), e.type)
            is AddrOf -> addr(e.e)
            is Cast -> castValue(value(e.e), e.e.type, e.type)
            is Unary -> unary(e)
            is Binary -> binary(e)
            is Chain -> chain(e)
            is Logical -> logical(e)
            is Assign -> assign(e, true)!!
            is IncDec -> incDec(e, true)!!
            is Call -> call(e, true) ?: XI(0)
            is Comma -> {
                for (i in 0 until e.xs.size - 1) discard(e.xs[i])
                valueRaw(e.xs.last())
            }
            is ArgvRef -> err("internal: argv", e)
        }
    }

    private fun funcPtr(fs: FuncSym): X {
        if (fs.isNative) return XNatPtr(fs.name)
        if (fs.index < 0) err("function '${fs.name}' has no index", Call(fs, null, fs.ftype, emptyList()).also { it.file = f.file; it.line = f.line })
        return XI(Program.FPTR_TAG or fs.index.toLong())
    }

    private fun loadVar(e: VarRef): X {
        val t = e.type
        return when (val s = e.sym) {
            is LocalSym -> {
                regVars[s]?.let { return XVar(it) }
                if (isAggregate(t)) XFp(s.offset) else loadT(XFp(s.offset), t)
            }
            is GlobalSym -> if (isAggregate(t)) XGlob(ctx.global(s)) else loadT(XGlob(ctx.global(s)), t)
            is FuncSym -> funcPtr(s)
        }
    }

    /** CodeGen.addr: the address of an lvalue. */
    private fun addr(e: Expr): X {
        at(e)
        return when (e) {
            is VarRef -> when (val s = e.sym) {
                is LocalSym -> {
                    if (regVars.containsKey(s)) err("internal: address of register local ${s.name}", e)
                    XFp(s.offset)
                }
                is GlobalSym -> XGlob(ctx.global(s))
                is FuncSym -> err("cannot take the address of a function this way", e)
            }
            is Deref -> word(value(e.e))
            is Index -> {
                val sz = maxOf(e.type.size, 1)
                val ci = ConstFold.int(e.idx)
                if (ci != null) {
                    val b = value(e.base)
                    val off = ci * sz
                    if (off == 0L) b else XOp(Op.ADD, b, XI(off))
                } else {
                    val (b, i0) = operands({ value(e.base) }, { value(e.idx) })
                    val i1 = if (e.idx.type is F64Type) XOp(Op.F2I, i0) else word(i0)
                    val i = if (sz != 1) XOp(Op.MUL, i1, XI(sz.toLong())) else i1
                    XOp(Op.ADD, b, i)
                }
            }
            is MemberAccess -> {
                val b = if (e.viaPtr) word(value(e.base)) else addr(e.base)
                if (e.offset != 0) XOp(Op.ADD, b, XI(e.offset.toLong())) else b
            }
            is Comma -> {
                for (i in 0 until e.xs.size - 1) discard(e.xs[i])
                addr(e.xs.last())
            }
            is Cast -> addr(e.e)
            else -> err("expression is not addressable", e)
        }
    }

    private fun unary(e: Unary): X {
        val x = value(e.e)
        val isF = e.e.type is F64Type
        return when (e.op) {
            "-" -> if (isF) XOp(Op.FNEG, x) else XOp(Op.NEG, word(x))
            "~" -> XOp(Op.COM, if (isF) XOp(Op.F2I, x) else word(x))
            "!" -> if (isF) XOp(Op.FEQ, x, XF(0.0.toRawBits())) else XOp(Op.EQ, word(x), XI(0))
            else -> err("unary ${e.op}", e)
        }
    }

    private val bitOps = setOf("&", "|", "^", "<<", ">>")

    private fun binary(e: Binary): X {
        val lt = e.l.type
        val rt = e.r.type
        val op0 = e.op
        if ((op0 == "+" || op0 == "-") && (Types.isPtrLike(lt) || Types.isPtrLike(rt))) {
            if (Types.isPtrLike(lt) && Types.isPtrLike(rt)) {
                val (a, b) = operands({ value(e.l) }, { value(e.r) })
                val d = XOp(Op.SUB, word(a), word(b))
                val sc = Types.scale(lt)
                return if (sc != 1) XOp(Op.DIVS, d, XI(sc.toLong())) else d
            }
            if (Types.isPtrLike(lt)) {
                val (a, b0) = operands({ value(e.l) }, { value(e.r) })
                var b = if (rt is F64Type) XOp(Op.F2I, b0) else word(b0)
                val sc = Types.scale(lt)
                if (sc != 1) b = XOp(Op.MUL, b, XI(sc.toLong()))
                return XOp(if (op0 == "+") Op.ADD else Op.SUB, word(a), b)
            }
            // integer + pointer (the VM adds for '-' too: CodeGen.binary)
            val (a0, b) = operands({ value(e.l) }, { value(e.r) })
            var a = if (lt is F64Type) XOp(Op.F2I, a0) else word(a0)
            val sc = Types.scale(rt)
            if (sc != 1) a = XOp(Op.MUL, a, XI(sc.toLong()))
            return XOp(Op.ADD, a, word(b))
        }
        val isF = (lt is F64Type || rt is F64Type || op0 == "`") && op0 !in bitOps
        val (a0, b0) = operands({ value(e.l) }, { value(e.r) })
        val a = if (isF) convert(a0, lt, Types.F64, e) else if (lt is F64Type) XOp(Op.F2I, a0) else word(a0)
        val b = if (isF) convert(b0, rt, Types.F64, e) else if (rt is F64Type) XOp(Op.F2I, b0) else word(b0)
        if (isF) return XOp(floatOp(op0, e), a, b)
        val unsigned = if (op0 in CMP_OPS) Types.isUnsignedAny(lt) || Types.isUnsignedAny(rt) else Types.isUnsigned64(lt) || Types.isUnsigned64(rt)
        return XOp(intOp(op0, unsigned, lt, e), a, b)
    }

    private fun floatOp(o: String, at: Expr) = when (o) {
        "+" -> Op.FADD; "-" -> Op.FSUB; "*" -> Op.FMUL; "/" -> Op.FDIV; "%" -> Op.FMOD; "`" -> Op.FPOW
        "==" -> Op.FEQ; "!=" -> Op.FNE; "<" -> Op.FLT; "<=" -> Op.FLE; ">" -> Op.FGT; ">=" -> Op.FGE
        else -> err("float operator $o", at)
    }

    private fun intOp(o: String, unsigned: Boolean, lt: Type, at: Expr) = when (o) {
        "+" -> Op.ADD; "-" -> Op.SUB; "*" -> Op.MUL
        "/" -> if (unsigned) Op.DIVU else Op.DIVS
        "%" -> if (unsigned) Op.MODU else Op.MODS
        "&" -> Op.AND; "|" -> Op.OR; "^" -> Op.XOR
        "<<" -> Op.SHL
        ">>" -> if (Types.isUnsigned64(lt)) Op.SHRU else Op.SHRS
        "`" -> Op.POWI
        "==" -> Op.EQ; "!=" -> Op.NE
        "<" -> if (unsigned) Op.LTU else Op.LTS
        "<=" -> if (unsigned) Op.LEU else Op.LES
        ">" -> if (unsigned) Op.GTU else Op.GTS
        ">=" -> if (unsigned) Op.GEU else Op.GES
        else -> err("integer operator $o", at)
    }

    /**
     * CodeGen.chain: `a<b<c` compares a,b then (only if true) b,c; every operand is evaluated once,
     * the later ones only while the comparisons hold.
     */
    private fun chain(e: Chain): X {
        val anyF = e.xs.any { it.type is F64Type }
        val anyU = e.xs.any { Types.isUnsignedAny(it.type) }
        fun conv(x: X, t: Type): X = if (anyF) convert(x, t, Types.F64, e) else word(x)
        fun cmp(o: String, a: X, b: X): X = XOp(if (anyF) floatOp(o, e) else intOp(o, anyU, Types.I64, e), a, b)
        val x0 = conv(value(e.xs[0]), e.xs[0].type)
        // Fast form: the later operands need no statements and the middle ones are plain values:
        // a && chain with each middle operand read twice (it cannot change in between).
        val scratch = ArrayList<List<S>>()
        val lowered = ArrayList<X>()
        val saveTmp = tmpN
        var simple = true
        for (i in 1 until e.xs.size) {
            val buf = ArrayList<S>()
            val x = into(buf) { lowered.add(conv(value(e.xs[i]), e.xs[i].type)) }
            scratch.add(buf)
            if (buf.isNotEmpty() || (i < e.xs.size - 1 && !trivial(lowered.last()))) simple = false
        }
        if (simple) {
            var prev = x0
            if (!stable(prev) && !trivial(prev)) prev = materialize(prev)
            var res: X? = null
            for (i in 1 until e.xs.size) {
                val c = cmp(e.ops[i - 1], prev, lowered[i - 1])
                res = if (res == null) c else XOp(Op.BAND, res, c)
                prev = lowered[i - 1]
            }
            return res!!
        }
        // General form: nested ifs into a flag, each operand lowered in its turn.
        tmpN = saveTmp
        val r = mutTemp(K.B)
        emit(SDecl(r, XB(false)))
        var prev = materialize(x0)
        val outer = cur
        var target = cur
        for (i in 1 until e.xs.size) {
            val x = intoX(target) { materialize(conv(value(e.xs[i]), e.xs[i].type)) }
            val c = cmp(e.ops[i - 1], prev, x)
            val inner = ArrayList<S>()
            if (i == e.xs.size - 1) inner.add(SSet(r, XB(true)).also { it.pos = curPos })
            target.add(SIf(c, inner, null).also { it.pos = curPos })
            target = inner
            prev = x
        }
        cur = outer
        return XVar(r)
    }

    private fun logical(e: Logical): X {
        when (e.op) {
            "^^" -> {
                val (a, b) = operands({ truth(valueRaw(e.l)) }, { truth(valueRaw(e.r)) })
                return XOp(Op.BXOR, a, b)
            }
            "&&", "||" -> {
                val a = truth(valueRaw(e.l))
                val buf = ArrayList<S>()
                val b = intoX(buf) { truth(valueRaw(e.r)) }
                if (buf.isEmpty()) return XOp(if (e.op == "&&") Op.BAND else Op.BOR, a, b)
                val r = mutTemp(K.B)
                emit(SDecl(r, a))
                buf.add(SSet(r, b).also { it.pos = curPos })
                emit(SIf(if (e.op == "&&") XVar(r) else XOp(Op.BNOT, XVar(r)), buf, null))
                return XVar(r)
            }
            else -> err("logical ${e.op}", e)
        }
    }

    // ---------------------------------------------------------------- assignment

    /** The register variable an lvalue names (through same-width casts: `p(I64 *)++`), or null. */
    private fun regTarget(target: Expr): Var? {
        var x = target
        while (x is Cast) x = x.e
        val r = (x as? VarRef)?.sym as? LocalSym ?: return null
        return regVars[r]
    }

    /** The declared type of the register local behind [target] (its value is kept extended for this type). */
    private fun regType(target: Expr): Type {
        var x = target
        while (x is Cast) x = x.e
        return ((x as VarRef).sym as LocalSym).type
    }

    /** CodeGen.assign. Returns the assignment's value (the converted, not narrowed, value). */
    private fun assign(e: Assign, want: Boolean): X? {
        val t = e.target.type
        if (t is ClassType && t.valueType == null) {
            if (e.op != "=") err("compound assignment to a class value", e)
            val (a, v) = operands({ addr(e.target) }, { word(value(e.value)) })
            emit(SCopy(a, v, t.size))
            val again = addr(e.target)
            return if (want) again else null
        }
        if (t is ArrType) err("cannot assign to an array", e)
        val rv = regTarget(e.target)
        if (rv != null) return assignReg(e, rv, t, regType(e.target), want)
        if (e.op == "=") {
            val xs = if (hasSideEffects(e.target)) operands({ convert(value(e.value), e.value.type, t, e) }, { addr(e.target) }).reversed()
            else operands({ addr(e.target) }, { convert(value(e.value), e.value.type, t, e) })
            var v = xs[1]
            if (want && !stable(v)) v = materialize(v)
            storeT(xs[0], v, t)
            return v
        }
        // compound: address, its old value, then the right-hand side
        val a0 = addr(e.target)
        val a = if (trivial(a0) && stable(a0)) a0 else materialize(a0)
        val (old, rhs) = operands({ loadT(a, t) }, { value(e.value) })
        var nv = compound(e, t, old, rhs)
        if (want && !stable(nv)) nv = materialize(nv)
        storeT(a, nv, t)
        return nv
    }

    private fun assignReg(e: Assign, rv: Var, t: Type, vt: Type, want: Boolean): X? {
        if (e.op == "=") {
            var v = convert(value(e.value), e.value.type, t, e)
            if (want && !stable(v)) v = materialize(v)
            emit(SSet(rv, narrow(v, vt)))
            return v
        }
        val (old, rhs) = operands({ XVar(rv) }, { value(e.value) })
        var nv = compound(e, t, old, rhs)
        if (want && !stable(nv)) nv = materialize(nv)
        emit(SSet(rv, narrow(nv, vt)))
        return nv
    }

    private fun compound(e: Assign, t: Type, old: X, rhs: X): X {
        val bop = e.op.dropLast(1)
        val rt = e.value.type
        if (Types.isPtrLike(t) && (bop == "+" || bop == "-")) {
            var r = if (rt is F64Type) XOp(Op.F2I, rhs) else word(rhs)
            val sc = Types.scale(t)
            if (sc != 1) r = XOp(Op.MUL, r, XI(sc.toLong()))
            return XOp(if (bop == "+") Op.ADD else Op.SUB, word(old), r)
        }
        if ((t is F64Type || rt is F64Type) && bop !in bitOps) {
            val a = convert(old, t, Types.F64, e)
            val b = convert(rhs, rt, Types.F64, e)
            return convert(XOp(floatOp(bop, e), a, b), Types.F64, t, e)
        }
        val r = if (rt is F64Type) XOp(Op.F2I, rhs) else word(rhs)
        return XOp(intOp(bop, Types.isUnsigned64(t) || Types.isUnsigned64(rt), t, e), word(old), r)
    }

    /** CodeGen.incDec / Vm.incAt: ++/-- with the target's width; pointers step by their element size. */
    private fun incDec(e: IncDec, want: Boolean): X? {
        val t = e.type
        val delta = if (Types.isPtrLike(t)) e.delta.toLong() * Types.scale(t) else e.delta.toLong()
        val rv = regTarget(e.target)
        fun next(old: X): X = if (t is F64Type) XOp(Op.FADD, old, XF((delta.toDouble()).toRawBits())) else XOp(Op.ADD, old, XI(delta))
        if (rv != null) {
            val vt = regType(e.target)
            if (!want) { emit(SSet(rv, narrow(next(XVar(rv)), vt))); return null }
            if (e.post) {
                val old = temp(rv.k); emit(SDecl(old, XVar(rv)))
                emit(SSet(rv, narrow(next(XVar(old)), vt)))
                return XVar(old)
            }
            emit(SSet(rv, narrow(next(XVar(rv)), vt)))
            return materialize(narrow(XVar(rv), t))
        }
        val a0 = addr(e.target)
        val a = if (trivial(a0) && stable(a0)) a0 else materialize(a0)
        val old = materialize(loadT(a, t))
        val nv = next(old)
        storeT(a, nv, t)
        if (!want) return null
        return if (e.post) old else materialize(narrow(nv, t))
    }

    private fun hasSideEffects(e: Expr?): Boolean = when (e) {
        null -> false
        is IncDec, is Assign, is Call -> true
        is Index -> hasSideEffects(e.base) || hasSideEffects(e.idx)
        is MemberAccess -> hasSideEffects(e.base)
        is Deref -> hasSideEffects(e.e)
        is Cast -> hasSideEffects(e.e)
        is Binary -> hasSideEffects(e.l) || hasSideEffects(e.r)
        is Unary -> hasSideEffects(e.e)
        is Comma -> e.xs.any { hasSideEffects(it) }
        else -> false
    }

    // ---------------------------------------------------------------- calls

    /** CodeGen.call. Returns the call's value (null for U0 or when unused). */
    private fun call(e: Call, want: Boolean): X? {
        val ft = e.ftype
        val params = ft.params
        val f0 = e.fn
        val a0 = e.args.singleOrNull()
        if (f0 != null && f0.isNative && a0 != null && !isAggregate(a0.type) &&
            (f0.name == "ToF64" && a0.type is F64Type || f0.name == "ToI64" && a0.type !is F64Type)) {
            val v = value(a0)
            return if (want) v else { discardValue(v); null }
        }
        if (e.args.size > params.size && !ft.varargs) err("too many arguments to ${e.fn?.name ?: "function"}", e)
        val direct = f0 != null && !f0.isNative
        val target = if (direct) ctx.fn(f0!!) else null
        val evals = ArrayList<() -> X>()
        for (i in params.indices) {
            val a = e.args.getOrNull(i)
            val prm = params[i]
            val ex = a ?: prm.default ?: err("missing argument '${prm.name}' to ${e.fn?.name ?: "function"}", e)
            evals.add {
                val v = value(ex)
                val c = if (isAggregate(prm.type) && !isAggregate(ex.type)) word(v) else convert(v, ex.type, prm.type, ex)
                // typed parameters only for direct calls; natives and pointers take words
                if (direct && target != null) c else word(c)
            }
        }
        for (i in params.size until e.args.size) {
            val a = e.args[i] ?: err("empty variadic argument", e)
            evals.add { word(value(a)) }
        }
        // CodeGen.call: arguments right to left (variadic ones from the last, then the fixed ones from the
        // last), as TempleOS evaluates them; the function pointer last
        val nArgs = evals.size
        val order = ArrayList<() -> X>(evals.asReversed())
        if (f0 == null) order.add { word(value(e.callee!!)) }
        val ys = operands(*order.toTypedArray())
        val xs = ArrayList<X>(ys.size).apply { for (i in nArgs - 1 downTo 0) add(ys[i]); if (f0 == null) add(ys.last()) }
        val fixed = ArrayList(xs.subList(0, params.size))
        if (direct && target != null) {
            // a prototype's parameter types may differ from the definition's: the callee reads the words as its own types
            for (i in fixed.indices) {
                val want = target.params.getOrNull(i) ?: K.I
                if (fixed[i].k != want) fixed[i] = if (want == K.F) XOp(Op.BITS2F, word(fixed[i])) else word(fixed[i])
            }
            while (fixed.size < target.params.size) fixed.add(if (target.params[fixed.size] == K.F) XF(0) else XI(0))
        }
        val extra = xs.subList(params.size, if (f0 == null) xs.size - 1 else xs.size)
        val retK: K? = when {
            ft.ret is VoidType -> null
            ft.ret is F64Type -> K.F
            else -> K.I
        }
        val res = if (want && retK != null) temp(retK) else null
        at(e)
        when {
            f0 == null -> emit(SCall(CPtr(xs.last()), fixed, extra.toList(), res, retK, tick = false))
            f0.isNative -> emit(SCall(CNative(f0.name, f0.nativeIndex), fixed, extra.toList(), res, retK, tick = false))
            target == null -> emit(SCall(CNative("\$undefined:${f0.name}", -1), fixed, extra.toList(), res, retK, tick = true))
            else -> {
                if (!target.varargs && extra.isNotEmpty()) err("too many arguments to ${f0.name}", e)
                emit(SCall(CDirect(target), fixed, extra.toList(), res, retK, tick = true))
            }
        }
        if (!want) return null
        return if (res != null) XVar(res) else XI(0)
    }

    // ---------------------------------------------------------------- discarded expressions

    /** Evaluates [e] for its effects (ExprStmt, comma operands), like the VM's value + POP. */
    private fun discard(e: Expr) {
        at(e)
        when (e) {
            is Assign -> assign(e, false)
            is IncDec -> incDec(e, false)
            is Call -> call(e, false)
            is Comma -> e.xs.forEach { discard(it) }
            else -> discardValue(valueRaw(e))
        }
    }

    /** A discarded value is still evaluated when evaluating it can fault (loads, division). */
    private fun discardValue(x: X) { if (canFault(x)) emit(SEval(x)) }

    private fun canFault(x: X): Boolean = when (x) {
        is XLoad, is XLoadF -> true
        is XOp -> x.op in setOf(Op.DIVS, Op.DIVU, Op.MODS, Op.MODU) || canFault(x.a) || (x.b != null && canFault(x.b))
        else -> false
    }

    // ---------------------------------------------------------------- statements

    /** Where break/continue/goto go: a structured label, or a block of the dispatch-loop fallback. */
    private sealed class Jump {
        class Brk(val label: String) : Jump()
        class Cont(val label: String) : Jump()
        class Mach(val target: Int, val tick: Boolean) : Jump()
    }

    private class LoopCtx(val brk: Jump, val cont: Jump?, val tryDepth: Int) { var contUsed = false }
    private val loops = ArrayList<LoopCtx>()
    private var tryDepth = 0
    private var tryN = 0

    private class GotoTarget(val jump: Jump, val tryDepth: Int)
    private val gotoTargets = HashMap<String, GotoTarget>()
    private lateinit var plan: GotoPlan

    fun lower(): IrFunction {
        curPos = Pos(f.file, f.line)
        plan = GotoPlan(cf.body)
        val body = into(ArrayList()) {
            // the VM stores an argument's whole word in the frame and reads a narrow parameter with its own width
            // (an I8 parameter passed 0xFF reads -1): narrow register parameters once, on entry
            for ((i, p) in ftype.params.withIndex()) {
                val v = params[i]
                if (paramSpills.any { it.first == i }) continue
                val n = narrow(XVar(v), p.type)
                if (n !is XVar) emit(SSet(v, n))
            }
            if (plan.unstructured) machineFunction(cf.body) else stmt(cf.body)
        }
        val isInit = f.name.startsWith("\$init") || f.name.startsWith("\$eval")
        return IrFunction(ref, f.name, f.file, f.line, params, paramSpills, locals,
            if (needFrame) f.frameSize else 0, if (ftype.varargs) f.argcSlot else -1, if (ftype.varargs) f.argvSlot else -1,
            body, isInit, argcVar, argvVar, plan.unstructured)
    }

    private fun stmtAt(s: Stmt) { if (s.line > 0) curPos = Pos(s.file, s.line) }

    private fun jump(j: Jump, targetTryDepth: Int) {
        if (tryDepth > targetTryDepth) emit(SHandlers(targetTryDepth - tryDepth))
        when (j) {
            is Jump.Brk -> emit(SBreak(j.label))
            is Jump.Cont -> { emit(STick()); emit(SContinue(j.label)) }
            is Jump.Mach -> emit(SGoto(machineLabel, stateVar!!, j.target, j.tick))
        }
    }

    fun stmt(s: Stmt) {
        stmtAt(s)
        when (s) {
            is Block -> blockList(s.list)
            is Nop -> {}
            is ExprStmt -> discard(s.e)
            is If -> {
                val c = cond(s.c)
                val t = into(ArrayList()) { stmt(s.t) }
                val fs = s.f
                val f = if (fs != null) into(ArrayList()) { stmt(fs) } else null
                stmtAt(s)
                emit(SIf(c, t, f))
            }
            is While -> loop(s, s.c, s.body, null, false)
            is DoWhile -> loop(s, s.c, s.body, null, true)
            is For -> {
                s.init?.let { stmt(it) }
                loop(s, s.c, s.body, s.step, false)
            }
            is Break -> {
                val lp = loops.lastOrNull() ?: err("break outside loop or switch", s)
                jump(lp.brk, lp.tryDepth)
            }
            is Continue -> {
                val lp = loops.lastOrNull { it.cont != null } ?: err("continue outside loop", s)
                lp.contUsed = true
                jump(lp.cont!!, lp.tryDepth)
            }
            is Return -> {
                val rt = ftype.ret
                val re = s.e
                if (re != null && rt !is VoidType) {
                    val v = narrow(convert(value(re), re.type, rt, re), rt)
                    stmtAt(s); emit(SReturn(v, tryDepth))
                } else {
                    if (re != null) discard(re)
                    stmtAt(s); emit(SReturn(null, tryDepth))
                }
            }
            is Goto -> {
                val g = gotoTargets[s.label] ?: err("goto ${s.label}: no target", s)
                val j = g.jump
                // the dispatch loop's jump direction is the VM's: by code layout order
                val jj = if (j is Jump.Mach) Jump.Mach(j.target, plan.backward(s)) else j
                jump(jj, g.tryDepth)
            }
            is Label -> {}
            is Try -> {
                val id = tryN++
                tryDepth++
                val body = into(ArrayList()) { stmt(s.body) }
                tryDepth--
                val h = into(ArrayList()) { stmt(s.handler) }
                stmtAt(s)
                emit(STry(id, body, h))
            }
            is LocalInit -> s.init?.let { initLocal(s.sym, it, s) }
            is GlobalInit -> initGlobal(s.sym, s.init, s)
            is Switch -> switchStmt(s)
            is CaseLabel, is SubStart, is SubEnd -> err("case label outside switch", s)
        }
    }

    /** A statement list, with labeled blocks / retry loops for its goto labels (see [GotoPlan]). */
    private fun blockList(list: List<Stmt>) {
        val ranges = plan.rangesFor(list)
        if (ranges.isEmpty()) { list.forEach { stmt(it) }; return }
        emitRanges(list, 0, list.size, ranges)
    }

    private fun emitRanges(list: List<Stmt>, from: Int, to: Int, ranges: List<GotoPlan.Range>) {
        val inside = ranges.filter { it.start >= from && it.end <= to }
        // outermost first: by start, longest first
        val sorted = inside.sortedWith(compareBy<GotoPlan.Range>({ it.start }, { -it.end }, { if (it.backward) 0 else 1 }))
        var i = from
        var k = 0
        while (k < sorted.size) {
            val r = sorted[k]
            if (r.start < i) { k++; continue } // nested in an earlier one
            while (i < r.start) stmt(list[i++])
            val inner = sorted.filter { it !== r && it.start >= r.start && it.end <= r.end }
            val nl = label(if (r.backward) "retry_" else "skip_")
            gotoTargets[r.label] = GotoTarget(if (r.backward) Jump.Cont(nl) else Jump.Brk(nl), tryDepth)
            val body = into(ArrayList()) { emitRanges(list, r.start, r.end, inner) }
            emit(if (r.backward) SRetryLoop(nl, body) else SBlock(nl, body))
            i = r.end
            k++
        }
        while (i < to) stmt(list[i++])
    }

    /** Condition of if/while/for: a Boolean, statements (calls, assignments) emitted first. */
    private fun cond(e: Expr): X = truth(valueRaw(e))

    /**
     * Loops as the VM lays them out: the test at the top (bottom for do-while), the body, the
     * `continue` point, the step, then the backward jump that charges one budget tick.
     */
    private fun loop(s: Stmt, c: Expr?, body: Stmt, step: Expr?, doWhile: Boolean) {
        val lbl = label("loop")
        val cont = label("cont")
        val ctx = LoopCtx(Jump.Brk(lbl), Jump.Brk(cont), tryDepth)
        loops.add(ctx)
        val bodyS = into(ArrayList()) { stmt(body) }
        loops.removeAt(loops.size - 1)
        val pre = ArrayList<S>()
        val cx = if (c != null) intoX(pre) { cond(c) } else null
        val post = if (step != null) into(ArrayList()) { discard(step) } else ArrayList()
        stmtAt(s)
        val always = cx is XB && cx.v && pre.isEmpty()
        emit(SLoop(lbl, pre, if (always) null else cx, bodyS, if (ctx.contUsed) cont else null, post, doWhile))
    }

    // ---------------------------------------------------------------- switch

    private fun switchValue(s: Switch): X {
        var v = value(s.e)
        if (s.e.type is F64Type) v = XOp(Op.F2I, v)
        return materialize(word(v))
    }

    private fun switchStmt(s: Switch) {
        val sw = switchValue(s)
        val items = s.body
        val label = label("switch")
        if (items.none { it is SubStart } && !StructureCheck.fallsThrough(items)) simpleSwitch(s, sw, items, label)
        else nestedSwitch(s, sw, items, label)
    }

    /** Value -> index of the case label it jumps to (the VM's table: a later label wins). */
    private fun caseTable(items: List<Stmt>, pick: (Int) -> Boolean, s: Stmt): Pair<java.util.TreeMap<Long, Int>, Int> {
        val table = java.util.TreeMap<Long, Int>()
        var dflt = -1
        var lo = Long.MAX_VALUE; var hi = Long.MIN_VALUE
        for ((i, st) in items.withIndex()) if (st is CaseLabel) {
            if (st.isDefault) { dflt = i; continue }
            if (!pick(i)) continue
            lo = minOf(lo, st.lo); hi = maxOf(hi, st.hi)
        }
        if (lo <= hi && hi - lo > 65536) err("switch case range too large for a jump table", s)
        for ((i, st) in items.withIndex()) if (st is CaseLabel && !st.isDefault && pick(i)) {
            var x = st.lo
            while (x <= st.hi) { table[x] = i; if (x == Long.MAX_VALUE) break; x++ }
        }
        return table to dflt
    }

    /** Ranges of consecutive values that jump to the same label. */
    private fun rangesByTarget(table: java.util.TreeMap<Long, Int>): Map<Int, List<LongRange>> {
        val out = LinkedHashMap<Int, ArrayList<LongRange>>()
        var start = 0L; var prev = 0L; var tgt = -1
        for ((k, t) in table) {
            if (tgt >= 0 && t == tgt && k == prev + 1) { prev = k; continue }
            if (tgt >= 0) out.getOrPut(tgt) { ArrayList() }.add(start..prev)
            start = k; prev = k; tgt = t
        }
        if (tgt >= 0) out.getOrPut(tgt) { ArrayList() }.add(start..prev)
        return out
    }

    /** A switch whose arms all end by leaving it: one `when`, `break` leaves the labeled block around it. */
    private fun simpleSwitch(s: Switch, sw: X, items: List<Stmt>, label: String) {
        val (table, dflt) = caseTable(items, { true }, s)
        val byTarget = rangesByTarget(table)
        val ctx = LoopCtx(Jump.Brk(label), null, tryDepth)
        loops.add(ctx)
        val arms = ArrayList<Arm>()
        var dfltBody: List<S>? = null
        var i = 0
        // statements before the first case label are never reached (the VM jumps over them)
        while (i < items.size && items[i] !is CaseLabel) i++
        while (i < items.size) {
            val labels = ArrayList<Int>()
            while (i < items.size && items[i] is CaseLabel) labels.add(i++)
            val bodyStmts = ArrayList<Stmt>()
            while (i < items.size && items[i] !is CaseLabel) bodyStmts.add(items[i++])
            val trimmed = if (bodyStmts.lastOrNull() is Break) bodyStmts.dropLast(1) else bodyStmts
            val body = into(ArrayList()) { trimmed.forEach { stmt(it) } }
            val ranges = labels.flatMap { byTarget[it] ?: emptyList() }.sortedBy { it.first }
            if (dflt in labels) dfltBody = body
            if (ranges.isNotEmpty()) arms.add(Arm(ranges, body))
        }
        loops.removeAt(loops.size - 1)
        stmtAt(s)
        emit(SBlock(label, listOf(SWhen(sw, arms, dfltBody).also { it.pos = curPos })))
    }

    /**
     * Switches with fallthrough or start:/end: groups. Every jump target (case label, group porch,
     * group end, the end of the switch) ends a breakable block; all blocks start before the dispatch
     * and nest by their end, so `break target` from the dispatch, from a group's porch dispatch, or
     * from a `break` lands where the VM's jump lands, and code falls through blocks as in the VM.
     */
    private fun nestedSwitch(s: Switch, sw: X, items: List<Stmt>, label: String) {
        class Group(val start: Int, var end: Int = -1, var firstCase: Int = -1)
        val groups = ArrayList<Group>()
        val groupOf = IntArray(items.size) { -1 }
        var g: Group? = null
        for ((i, st) in items.withIndex()) {
            when (st) {
                is SubStart -> { if (g != null) err("nested start: blocks are not supported", st); g = Group(i); groups.add(g) }
                is SubEnd -> { if (g == null) err("end: without start:", st); g.end = i; g = null }
                is CaseLabel -> if (g != null && !st.isDefault) { groupOf[i] = groups.size - 1; if (g.firstCase < 0) g.firstCase = i }
                else -> {}
            }
        }
        if (g != null) err("start: without end:", s)
        val (table, dflt) = caseTable(items, { true }, s)
        val targets = java.util.TreeSet<Int>()
        targets.add(items.size)
        if (dflt >= 0) targets.add(dflt)
        for ((_, t) in table) targets.add(t)
        for (gr in groups) { targets.add(gr.start); targets.add(gr.end) }
        val names = HashMap<Int, String>()
        for (p in targets) names[p] = "${label}_$p"
        val endLabel = names[items.size]!!
        val dfltTarget = if (dflt >= 0) dflt else items.size
        fun dispatch(gi: Int): S {
            val (tab, _) = caseTable(items, { if (gi < 0) true else groupOf[it] == gi }, s)
            val arms = rangesByTarget(tab).map { (t, rs) ->
                val dest = if (gi < 0 && groupOf[t] >= 0) groups[groupOf[t]].start else t
                Arm(rs, listOf(SBreak(names[dest]!!).also { it.pos = curPos }))
            }
            return SWhen(sw, arms, listOf(SBreak(names[dfltTarget]!!).also { it.pos = curPos })).also { it.pos = curPos }
        }
        loops.add(LoopCtx(Jump.Brk(endLabel), null, tryDepth))
        var content = ArrayList<S>()
        content.add(dispatch(-1))
        var from = 0
        for (p in targets) {
            into(content) {
                for (i in from until p) {
                    when (val st = items[i]) {
                        is CaseLabel -> {}
                        is SubStart -> {
                            val gr = groups.first { it.start == i }
                            loops.add(LoopCtx(Jump.Brk(names[gr.end]!!), null, tryDepth))
                        }
                        is SubEnd -> loops.removeAt(loops.size - 1)
                        is Label -> err("label inside a switch body", st)
                        else -> stmt(st)
                    }
                }
                // a group's porch dispatch runs right before its first case label
                val gi = groups.indexOfFirst { it.firstCase == p }
                if (gi >= 0) emit(dispatch(gi))
            }
            content = arrayListOf(SBlock(names[p]!!, content).also { it.pos = curPos })
            from = p
        }
        loops.removeAt(loops.size - 1)
        stmtAt(s)
        emit(content.single())
    }

    // ---------------------------------------------------------------- initializers

    private fun initLocal(sym: LocalSym, init: Init, s: Stmt) {
        val rv = regVars[sym]
        if (rv != null) {
            val e = when (init) {
                is ExprInit -> init.e
                is ListInit -> (init.items.firstOrNull() as? ExprInit)?.e ?: return
            }
            emit(SSet(rv, narrow(convert(value(e), e.type, sym.type, e), sym.type)))
            return
        }
        storeInit(sym.type, init, s) { off -> XFp(sym.offset + off) }
    }

    private fun initGlobal(sym: GlobalSym, init: Init, s: Stmt) {
        if (ConstInit.isConst(sym.type, init)) return // written by the data segment (CodeGen.constStore)
        storeInit(sym.type, init, s) { off -> val g = XGlob(ctx.global(sym)); if (off == 0) g else XOp(Op.ADD, g, XI(off.toLong())) }
    }

    private fun storeInit(t: Type, init: Init, s: Stmt, addrOf: (Int) -> X) {
        fun rec(t: Type, init: Init, off: Int) {
            when (init) {
                is ListInit -> when (t) {
                    is ArrType -> init.items.forEachIndexed { i, it -> rec(t.elem, it, off + i * t.elem.size) }
                    is ClassType -> {
                        val ms = t.members.values.toList()
                        init.items.forEachIndexed { i, it ->
                            if (i >= ms.size) err("too many initializers", s)
                            rec(ms[i].type, it, off + ms[i].offset)
                        }
                    }
                    else -> rec(t, init.items.firstOrNull() ?: return, off)
                }
                is ExprInit -> {
                    val e = init.e
                    if (t is ArrType && e is StrLit) {
                        emit(SCopy(addrOf(off), XStr(ctx.string(e.bytes)), minOf(e.bytes.size + 1, t.size)))
                        return
                    }
                    if (t is ClassType && t.valueType == null) {
                        val (a, v) = operands({ addrOf(off) }, { word(value(e)) })
                        emit(SCopy(a, v, t.size)); return
                    }
                    val (a, v) = operands({ addrOf(off) }, { convert(value(e), e.type, t, e) })
                    storeT(a, v, t)
                }
            }
        }
        rec(t, init, 0)
    }

    // ---------------------------------------------------------------- dispatch-loop fallback

    private var machineLabel = ""
    private var stateVar: Var? = null
    private val mBlocks = ArrayList<ArrayList<S>>()
    private val mRegionOf = ArrayList<Int>()
    private val mRegions = ArrayList<MRegion>()
    private var mRegion = -1
    private var mCur = 0
    private val labelBlocks = HashMap<String, Int>()

    private fun newBlock(): Int { mBlocks.add(ArrayList()); mRegionOf.add(mRegion); return mBlocks.size - 1 }

    private fun startBlock(id: Int) { mCur = id; cur = mBlocks[id] }

    private fun goto(target: Int, tick: Boolean) = emit(SGoto(machineLabel, stateVar!!, target, tick))

    /**
     * For functions whose gotos cannot be structured (a jump into another branch): numbered blocks
     * run by a dispatch loop. Only statements that contain labels are split into blocks; everything
     * else stays structured inside a block, its jumps written as `state = n; continue`.
     */
    private fun machineFunction(body: Stmt) {
        machineLabel = label("machine")
        val sv = Var("state", K.I, true)
        stateVar = sv
        val outer = cur
        val entry = newBlock()
        for (name in plan.labelNames) labelBlocks[name] = -1
        startBlock(entry)
        lin(body)
        // falling off the end returns like the VM's implicit return
        emit(SReturn(if (ftype.ret is VoidType) null else XI(0).let { if (ftype.ret is F64Type) XOp(Op.BITS2F, it) else it }, tryDepth))
        cur = outer
        val blocks = mBlocks.mapIndexed { i, b -> MBlock(i, b, mRegionOf[i]) }
        emit(SMachine(machineLabel, sv, blocks, mRegions))
    }

    private fun labelBlock(name: String): Int {
        val b = labelBlocks[name]
        if (b != null && b >= 0) return b
        val n = newBlock()
        labelBlocks[name] = n
        gotoTargets[name] = GotoTarget(Jump.Mach(n, false), plan.tryDepthOf(name))
        return n
    }

    private val labelTryDepth = HashMap<String, Int>()

    /** Lowers [s] into blocks if it contains a label; otherwise as structured code in the current block. */
    private fun lin(s: Stmt) {
        if (!plan.containsLabel(s)) {
            // gotos inside jump to blocks: make sure every label has one
            for (name in plan.gotoNames(s)) labelBlock(name)
            stmt(s)
            return
        }
        stmtAt(s)
        when (s) {
            is Block -> s.list.forEach { lin(it) }
            is Label -> {
                labelTryDepth[s.name] = tryDepth
                val b = labelBlock(s.name)
                gotoTargets[s.name] = GotoTarget(Jump.Mach(b, false), tryDepth)
                goto(b, false)
                startBlock(b)
            }
            is If -> {
                val c = cond(s.c)
                val tb = newBlock()
                val fb = if (s.f != null) newBlock() else -1
                val jb = newBlock()
                val gt = ArrayList<S>().also { it.add(SGoto(machineLabel, stateVar!!, tb, false).also { g -> g.pos = curPos }) }
                val gf = ArrayList<S>().also { it.add(SGoto(machineLabel, stateVar!!, if (fb >= 0) fb else jb, false).also { g -> g.pos = curPos }) }
                emit(SIf(c, gt, gf))
                startBlock(tb); lin(s.t); goto(jb, false)
                if (fb >= 0) { startBlock(fb); lin(s.f!!); goto(jb, false) }
                startBlock(jb)
            }
            is While, is For, is DoWhile -> machineLoop(s)
            is Switch -> machineSwitch(s)
            is Try -> {
                val id = mRegions.size
                val handler = newBlock()
                val region = MRegion(id, handler, mRegion)
                mRegions.add(region)
                // the handler and everything after it belong to the enclosing region
                mRegionOf[handler] = mRegion
                emit(SRegionEnter(region))
                val saved = mRegion
                mRegion = id
                val body = newBlock()
                goto(body, false)
                startBlock(body)
                tryDepth++
                lin(s.body)
                tryDepth--
                emit(SHandlers(-1))
                mRegion = saved
                val join = newBlock()
                goto(join, false)
                startBlock(handler)
                lin(s.handler)
                emit(SEndCatch())
                goto(join, false)
                startBlock(join)
            }
            else -> stmt(s)
        }
    }

    private fun machineLoop(s: Stmt) {
        val c: Expr?; val body: Stmt; val step: Expr?; val doWhile: Boolean
        when (s) {
            is While -> { c = s.c; body = s.body; step = null; doWhile = false }
            is DoWhile -> { c = s.c; body = s.body; step = null; doWhile = true }
            is For -> { s.init?.let { lin(it) }; c = s.c; body = s.body; step = s.step; doWhile = false }
            else -> error("loop")
        }
        val head = newBlock()
        val bodyB = newBlock()
        val contB = newBlock()
        val exit = newBlock()
        loops.add(LoopCtx(Jump.Mach(exit, false), Jump.Mach(contB, false), tryDepth))
        if (doWhile) {
            goto(bodyB, false)
            startBlock(head) // unused for do-while: the test is in contB
            goto(bodyB, false)
        } else {
            goto(head, false)
            startBlock(head)
            if (c != null) {
                val cx = cond(c)
                emit(SIf(XOp(Op.BNOT, cx), arrayListOf(SGoto(machineLabel, stateVar!!, exit, false).also { it.pos = curPos }), null))
            }
            goto(bodyB, false)
        }
        startBlock(bodyB)
        lin(body)
        goto(contB, false)
        startBlock(contB)
        loops.removeAt(loops.size - 1)
        if (doWhile) {
            val cx = if (c != null) cond(c) else XB(true)
            emit(SIf(cx, arrayListOf(SGoto(machineLabel, stateVar!!, bodyB, true).also { it.pos = curPos }), null))
            goto(exit, false)
        } else {
            if (step != null) discard(step)
            goto(head, true)
        }
        startBlock(exit)
    }

    private fun machineSwitch(s: Switch) {
        val sw = switchValue(s)
        val items = s.body
        if (items.any { it is SubStart }) err("start:/end: groups in a switch with labels are not supported", s)
        val (table, dflt) = caseTable(items, { true }, s)
        val blockAt = HashMap<Int, Int>()
        for ((i, st) in items.withIndex()) if (st is CaseLabel) blockAt[i] = newBlock()
        val exit = newBlock()
        val arms = rangesByTarget(table).map { (t, rs) -> Arm(rs, listOf(SGoto(machineLabel, stateVar!!, blockAt[t]!!, false).also { it.pos = curPos })) }
        emit(SWhen(sw, arms, listOf(SGoto(machineLabel, stateVar!!, if (dflt >= 0) blockAt[dflt]!! else exit, false).also { it.pos = curPos })))
        loops.add(LoopCtx(Jump.Mach(exit, false), null, tryDepth))
        // unreachable statements before the first label still need a block
        startBlock(newBlock())
        for ((i, st) in items.withIndex()) {
            if (st is CaseLabel) { val b = blockAt[i]!!; goto(b, false); startBlock(b) } else lin(st)
        }
        loops.removeAt(loops.size - 1)
        goto(exit, false)
        startBlock(exit)
    }

    companion object {
        val CMP_OPS = setOf("<", "<=", ">", ">=", "==", "!=")

        fun ident(n: String): String {
            val sb = StringBuilder()
            for (c in n) sb.append(if (c.isLetterOrDigit() && c.code < 128 || c == '_') c else '_')
            if (sb.isEmpty() || sb[0].isDigit()) sb.insert(0, '_')
            return sb.toString()
        }
    }
}

/** CodeGen.isConstInit: global initializers the compiler writes into the arena at compile time. */
object ConstInit {
    fun isConst(t: Type, init: Init): Boolean = when (init) {
        is ListInit -> when (t) {
            is ArrType -> init.items.all { isConst(t.elem, it) }
            is ClassType -> {
                val ms = t.members.values.toList()
                init.items.withIndex().all { (i, it) -> i < ms.size && isConst(ms[i].type, it) }
            }
            else -> init.items.size == 1 && isConst(t, init.items[0])
        }
        is ExprInit -> when {
            t is ArrType && init.e is StrLit -> true
            t is F64Type -> ConstFold.float(init.e) != null
            Types.isInt(t) || t is PtrType -> ConstFold.int(init.e) != null && init.e.type !is F64Type || init.e is StrLit
            else -> false
        }
    }
}

object StructureCheck {
    /** True when a non-empty arm can run into the next case label (no break/return/continue/goto at its end). */
    fun fallsThrough(items: List<Stmt>): Boolean {
        var seenCase = false
        var last: Stmt? = null
        var nonEmpty = false
        for (st in items) {
            if (st is CaseLabel) {
                if (seenCase && nonEmpty && !(last is Break || last is Return || last is Continue || last is Goto)) return true
                seenCase = true; nonEmpty = false; last = null
                continue
            }
            if (st is SubStart || st is SubEnd) return true
            nonEmpty = true; last = st
        }
        return false
    }
}
