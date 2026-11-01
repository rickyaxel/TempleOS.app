package io.github.templeosmobile.core.holyc

/**
 * Lowers the typed AST to stack bytecode in [Program.code].
 *
 * Value representation on the operand stack: every value is 64 bits. Integers
 * are sign/zero-extended from their storage type, F64 values are raw IEEE bits,
 * pointers and arrays are arena addresses, class values are their address.
 */
class CodeGen(private val prog: Program) {
    private lateinit var fn: FuncSym
    private var frameSize = 0
    private val labels = HashMap<String, Int>()
    private val labelTry = HashMap<String, Int>()
    private val gotoPatches = ArrayList<Triple<Int, String, Int>>() // (operand pos, label, tryDepth)
    private var tryDepth = 0

    private class Loop(val breakPatches: ArrayList<Int>, val contPatches: ArrayList<Int>?, val tryDepth: Int, val isSwitchGroup: Boolean = false)
    private val loops = ArrayList<Loop>()

    // ------------------------------------------------------------ emission

    private val code get() = prog.code
    private var lastOp = -1
    private var labelAt = -1 // pc that is a jump target (peephole barrier)
    private var curFile = ""
    private var curLine = 0

    private fun pc() = code.size
    private fun op(o: Int, vararg a: Int) {
        // peephole: STKn + POP -> STn ; LSTK8 + POP -> LST8
        if (o == Op.POP && lastOp >= 0 && labelAt != pc()) {
            val prev = code[lastOp]
            val repl = when (prev) {
                Op.STK1 -> Op.ST1; Op.STK2 -> Op.ST2; Op.STK4 -> Op.ST4; Op.STK8 -> Op.ST8
                Op.LSTK8 -> Op.LST8
                else -> -1
            }
            if (repl >= 0) { code[lastOp] = repl; return }
            if ((prev == Op.LINC8 || prev == Op.INC) ) {
                // value of an increment is unused: keep instruction, pop result
            }
        }
        lastOp = pc()
        prog.markLine(pc(), curFile, curLine)
        code.add(o)
        for (x in a) code.add(x)
    }

    private fun here(): Int { labelAt = pc(); return pc() }
    private fun patch(pos: Int, target: Int) { code[pos] = target }
    /** Emits a jump with a placeholder; returns the operand position to patch. */
    private fun jump(o: Int): Int { op(o, 0); return pc() - 1 }

    private fun allocTemp(size: Int = 8): Int {
        frameSize = (frameSize + 7) and 7.inv()
        val off = frameSize
        frameSize += size
        return off
    }

    private fun err(msg: String, e: Expr): Nothing = throw CompileError(msg, e.file, e.line)
    private fun err(msg: String, s: Stmt): Nothing = throw CompileError(msg, s.file, s.line)

    // ------------------------------------------------------------ functions

    private var nesting = 0
    private var quickFrom = 0

    fun compileFunction(f: FuncSym, body: Stmt) {
        if (nesting++ == 0) quickFrom = pc()
        try { compileFunction0(f, body) } finally { nesting-- }
        if (nesting == 0) Quick.quicken(code, quickFrom, pc())
    }

    /**
     * TempleOS returns whatever is in RAX when a non-U0 function falls off its
     * end; programs rely on that (Apps/X-Caliber ShotNew ends with QueIns()).
     * The common case is mirrored: a trailing expression statement becomes the
     * return value.
     */
    private fun fallOffValue(f: FuncSym, body: Stmt): Stmt {
        if (f.ftype.ret is VoidType || body !is Block || body.list.isEmpty()) return body
        val last = body.list.last() as? ExprStmt ?: return body
        if (last.e.type is VoidType) return body
        val ret = Return(last.e).also { it.file = last.file; it.line = last.line }
        return Block(body.list.dropLast(1) + ret).also { it.file = body.file; it.line = body.line }
    }

    private fun compileFunction0(f: FuncSym, body: Stmt) {
        fn = f
        frameSize = f.frameSize
        labels.clear(); labelTry.clear(); gotoPatches.clear(); loops.clear()
        tryDepth = 0
        lastOp = -1
        f.entry = pc()
        here()
        curFile = f.file; curLine = f.line
        val body1 = fallOffValue(f, body)
        stmt(body1)
        // implicit return
        op(Op.PUSHI, 0)
        op(Op.RET)
        for ((pos, name, td) in gotoPatches) {
            val t = labels[name] ?: throw CompileError("undefined label '$name'", f.file, f.line)
            code[pos] = t
        }
        f.frameSize = (frameSize + 7) and 7.inv()
        prog.registerFunc(f)
        prog.observer?.function(f, body1)
    }

    // ------------------------------------------------------------ statements

    private fun stmt(s: Stmt) {
        if (s.line > 0) { curFile = s.file; curLine = s.line }
        when (s) {
            is Block -> s.list.forEach { stmt(it) }
            is Nop -> {}
            is ExprStmt -> { value(s.e); op(Op.POP) }
            is If -> {
                val jf = cond(s.c, false)
                stmt(s.t)
                if (s.f != null) {
                    val je = jump(Op.JMP)
                    patchAll(jf, here())
                    stmt(s.f)
                    patch(je, here())
                } else patchAll(jf, here())
            }
            is While -> {
                val top = here()
                val jf = cond(s.c, false)
                val lp = Loop(ArrayList(), ArrayList(), tryDepth)
                loops.add(lp)
                stmt(s.body)
                loops.removeAt(loops.size - 1)
                val cont = here()
                op(Op.JMP, top)
                val end = here()
                patchAll(jf, end)
                lp.breakPatches.forEach { patch(it, end) }
                lp.contPatches!!.forEach { patch(it, cont) }
            }
            is DoWhile -> {
                val top = here()
                val lp = Loop(ArrayList(), ArrayList(), tryDepth)
                loops.add(lp)
                stmt(s.body)
                loops.removeAt(loops.size - 1)
                val cont = here()
                val jt = cond(s.c, true)
                patchAll(jt, top)
                val end = here()
                lp.breakPatches.forEach { patch(it, end) }
                lp.contPatches!!.forEach { patch(it, cont) }
            }
            is For -> {
                s.init?.let { stmt(it) }
                val top = here()
                val jf = if (s.c != null) cond(s.c, false) else emptyList()
                val lp = Loop(ArrayList(), ArrayList(), tryDepth)
                loops.add(lp)
                stmt(s.body)
                loops.removeAt(loops.size - 1)
                val cont = here()
                s.step?.let { value(it); op(Op.POP) }
                op(Op.JMP, top)
                val end = here()
                patchAll(jf, end)
                lp.breakPatches.forEach { patch(it, end) }
                lp.contPatches!!.forEach { patch(it, cont) }
            }
            is Break -> {
                val lp = loops.lastOrNull() ?: err("break outside loop or switch", s)
                repeat(tryDepth - lp.tryDepth) { op(Op.UNTRY) }
                lp.breakPatches.add(jump(Op.JMP))
            }
            is Continue -> {
                val lp = loops.lastOrNull { it.contPatches != null } ?: err("continue outside loop", s)
                repeat(tryDepth - lp.tryDepth) { op(Op.UNTRY) }
                lp.contPatches!!.add(jump(Op.JMP))
            }
            is Return -> {
                val rt = fn.ftype.ret
                if (s.e != null) {
                    value(s.e)
                    if (rt !is VoidType) convert(s.e.type, rt, s.e) else { op(Op.POP); op(Op.PUSHI, 0) }
                    narrow(rt)
                } else op(Op.PUSHI, 0)
                op(Op.RET)
            }
            is Goto -> {
                op(Op.JMP, 0)
                gotoPatches.add(Triple(pc() - 1, s.label, tryDepth))
            }
            is Label -> { labels[s.name] = here(); labelTry[s.name] = tryDepth }
            is Try -> {
                val tryPos = jump(Op.TRY)
                tryDepth++
                stmt(s.body)
                tryDepth--
                op(Op.UNTRY)
                val je = jump(Op.JMP)
                patch(tryPos, here())
                stmt(s.handler)
                op(Op.ENDCATCH)
                patch(je, here())
            }
            is LocalInit -> s.init?.let { initLocal(s.sym, it, s) }
            is GlobalInit -> initGlobal(s.sym, s.init, s)
            is Switch -> switchStmt(s)
            is CaseLabel, is SubStart, is SubEnd -> err("case label outside switch", s)
        }
    }

    private fun patchAll(list: List<Int>, target: Int) = list.forEach { patch(it, target) }

    /** Emits a conditional jump taken when [c] is [whenTrue]; returns patch positions. */
    private fun cond(c: Expr, whenTrue: Boolean): List<Int> {
        if (!whenTrue && c is Binary && c.op in CMP_OPS && isIntOrPtr(c.l.type) && isIntOrPtr(c.r.type) &&
            !Types.isUnsignedAny(c.l.type) && !Types.isUnsignedAny(c.r.type)) {
            value(c.l); value(c.r)
            val o = when (c.op) { "<" -> Op.JLTS; "<=" -> Op.JLES; ">" -> Op.JGTS; ">=" -> Op.JGES; "==" -> Op.JEQ; else -> Op.JNE }
            return listOf(jump(o))
        }
        if (c is Logical && c.op == "&&" && !whenTrue) {
            return cond(c.l, false) + cond(c.r, false)
        }
        if (c is Logical && c.op == "||" && whenTrue) {
            return cond(c.l, true) + cond(c.r, true)
        }
        if (c is Unary && c.op == "!") return cond(c.e, !whenTrue)
        value(c)
        if (c.type is F64Type) { op(Op.PUSHK, prog.konst(0.0.toRawBits())); op(Op.FNE) }
        return listOf(jump(if (whenTrue) Op.JNZ else Op.JZ))
    }

    private fun isIntOrPtr(t: Type) = Types.isInt(t) || Types.isPtrLike(t)

    // ------------------------------------------------------------ switch

    private class CaseInfo(val lo: Long, val hi: Long, var pc: Int = -1, val group: Int)

    private fun switchStmt(s: Switch) {
        value(s.e)
        if (s.e.type is F64Type) op(Op.F2I)
        val tmp = allocTemp()
        op(Op.LST8, tmp)
        // collect labels (only direct children; nested switches have their own)
        val cases = ArrayList<CaseInfo>()
        var dflt: CaseInfo? = null
        val groups = ArrayList<IntArray>() // [startPc, endPatchListIndex]
        var curGroup = -1
        var groupCounter = 0
        for (st in s.body) {
            when (st) {
                is CaseLabel -> if (st.isDefault) dflt = CaseInfo(0, 0, group = curGroup) else cases.add(CaseInfo(st.lo, st.hi, group = curGroup))
                // Nested start:/end: groups (legal in TempleOS, Compiler/PrsStmt.HC) are not
                // supported: a compile error instead of a malformed dispatch table.
                is SubStart -> if (curGroup >= 0) err("nested start: blocks are not supported", st) else curGroup = groupCounter++
                is SubEnd -> if (curGroup < 0) err("end: without start:", st) else curGroup = -1
                else -> {}
            }
        }
        val dispatchPos = pc()
        op(Op.LLD8, tmp)
        val tableIdx = prog.switchTables.size
        prog.switchTables.add(SwitchTable(0, 0, IntArray(0))) // placeholder
        op(Op.SWITCH, tableIdx)
        val groupStart = IntArray(groupCounter) { -1 }
        val groupEndPatches = Array(groupCounter) { ArrayList<Int>() }
        val groupPorchDispatch = IntArray(groupCounter) { -1 }
        val outer = Loop(ArrayList(), null, tryDepth)
        loops.add(outer)
        var ci = 0
        var inGroup = -1
        var groupIdx = -1
        var porchOpen = false
        for (st in s.body) {
            when (st) {
                is CaseLabel -> {
                    if (porchOpen) {
                        // end of the front porch: dispatch among this group's cases
                        op(Op.LLD8, tmp)
                        groupPorchDispatch[inGroup] = prog.switchTables.size
                        prog.switchTables.add(SwitchTable(0, 0, IntArray(0)))
                        op(Op.SWITCH, groupPorchDispatch[inGroup])
                        porchOpen = false
                    }
                    val target = here()
                    if (st.isDefault) dflt!!.pc = target else cases[ci++].pc = target
                }
                is SubStart -> {
                    groupIdx++
                    inGroup = groupIdx
                    groupStart[inGroup] = here()
                    porchOpen = true
                    loops.add(Loop(groupEndPatches[inGroup], null, tryDepth, isSwitchGroup = true))
                }
                is SubEnd -> {
                    if (porchOpen) { porchOpen = false }
                    loops.removeAt(loops.size - 1)
                    val endPc = here()
                    groupEndPatches[inGroup].forEach { patch(it, endPc) }
                    inGroup = -1
                }
                else -> stmt(st)
            }
        }
        if (inGroup >= 0) loops.removeAt(loops.size - 1)
        loops.removeAt(loops.size - 1)
        val end = here()
        outer.breakPatches.forEach { patch(it, end) }
        val dfltPc = dflt?.pc ?: end
        // main table: group cases jump to their group's porch
        prog.switchTables[tableIdx] = buildTable(cases.map {
            Triple(it.lo, it.hi, if (it.group >= 0) groupStart[it.group] else it.pc)
        }, dfltPc, s)
        for (g in 0 until groupCounter) {
            val ti = groupPorchDispatch[g]
            if (ti < 0) continue
            prog.switchTables[ti] = buildTable(cases.filter { it.group == g }.map { Triple(it.lo, it.hi, it.pc) }, dfltPc, s)
        }
    }

    private fun buildTable(entries: List<Triple<Long, Long, Int>>, dflt: Int, s: Stmt): SwitchTable {
        if (entries.isEmpty()) return SwitchTable(0, dflt, IntArray(0))
        val lo = entries.minOf { it.first }
        val hi = entries.maxOf { it.second }
        if (hi - lo > 65536) err("switch case range too large for a jump table", s)
        val t = IntArray((hi - lo + 1).toInt()) { dflt }
        for ((a, b, target) in entries) for (v in a..b) t[(v - lo).toInt()] = target
        return SwitchTable(lo, dflt, t)
    }

    // ------------------------------------------------------------ initializers

    private fun initLocal(sym: LocalSym, init: Init, s: Stmt) {
        storeInit(sym.type, init, s) { off -> op(Op.LADDR, sym.offset + off) }
    }

    private fun initGlobal(sym: GlobalSym, init: Init, s: Stmt) {
        if (constStore(sym.type, init, sym.addr)) return
        storeInit(sym.type, init, s) { off -> op(Op.PUSHI, sym.addr + off) }
    }

    /** Writes constant initializers straight into the arena. Returns false if not constant. */
    private fun constStore(t: Type, init: Init, addr: Int): Boolean {
        if (!isConstInit(t, init)) return false
        writeConst(t, init, addr)
        return true
    }

    private fun isConstInit(t: Type, init: Init): Boolean = when (init) {
        is ListInit -> when (t) {
            is ArrType -> init.items.all { isConstInit(t.elem, it) }
            is ClassType -> {
                val ms = t.members.values.toList()
                init.items.withIndex().all { (i, it) -> i < ms.size && isConstInit(ms[i].type, it) }
            }
            else -> init.items.size == 1 && isConstInit(t, init.items[0])
        }
        is ExprInit -> when {
            t is ArrType && init.e is StrLit -> true
            t is F64Type -> ConstFold.float(init.e) != null
            Types.isInt(t) || t is PtrType -> ConstFold.int(init.e) != null && init.e.type !is F64Type || init.e is StrLit
            else -> false
        }
    }

    // Every store is checked like a VM store (Arena.check): an initializer list longer than its array
    // (`U8 g[0][N]={{0},{65}};`) or a huge dimension must fault (BadMem), never write outside the arena.
    private fun writeConst(t: Type, init: Init, addr: Int) {
        val mem = prog.vm.mem
        when (init) {
            is ListInit -> when (t) {
                is ArrType -> init.items.forEachIndexed { i, it -> writeConst(t.elem, it, addr + i * t.elem.size) }
                is ClassType -> {
                    val ms = t.members.values.toList()
                    init.items.forEachIndexed { i, it -> writeConst(ms[i].type, it, addr + ms[i].offset) }
                }
                else -> writeConst(t, init.items[0], addr)
            }
            is ExprInit -> {
                val e = init.e
                if (t is ArrType && e is StrLit) {
                    val n = maxOf(minOf(e.bytes.size, t.size), 0)
                    mem.check(addr.toLong(), n)
                    for (i in 0 until n) mem.st1(addr + i, e.bytes[i].toLong())
                    return
                }
                val v: Long = when {
                    t is F64Type -> ConstFold.float(e)!!.toRawBits()
                    e is StrLit -> prog.stringAddr(e.bytes).toLong()
                    else -> ConstFold.int(e)!!
                }
                mem.check(addr.toLong(), when (t.size) { 1, 2, 4 -> t.size; else -> 8 }) // the width stored below
                prog.observer?.constWrite(addr, t.size, v, t !is F64Type && e is StrLit)
                when (t.size) {
                    1 -> mem.st1(addr, v); 2 -> mem.st2(addr, v); 4 -> mem.st4(addr, v); else -> mem.st8(addr, v)
                }
            }
        }
    }

    private fun storeInit(t: Type, init: Init, s: Stmt, addrOf: (Int) -> Unit) {
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
                        addrOf(off)
                        op(Op.PUSHI, prog.stringAddr(e.bytes))
                        op(Op.MEMCPY, minOf(e.bytes.size + 1, t.size))
                        return
                    }
                    if (t is ClassType && t.valueType == null) {
                        addrOf(off); value(e); op(Op.MEMCPY, t.size); return
                    }
                    addrOf(off)
                    value(e)
                    convert(e.type, t, e)
                    op(storeOp(t))
                }
            }
        }
        rec(t, init, 0)
    }

    // ------------------------------------------------------------ expressions

    private fun loadOp(t: Type): Int {
        val it = Types.asInt(t)
        if (it != null) return when (it.size) {
            1 -> if (it.signed) Op.LD1S else Op.LD1U
            2 -> if (it.signed) Op.LD2S else Op.LD2U
            4 -> if (it.signed) Op.LD4S else Op.LD4U
            else -> Op.LD8
        }
        return Op.LD8
    }

    private fun storeOp(t: Type, keep: Boolean = false): Int {
        val size = Types.asInt(t)?.size ?: 8
        return when (size) {
            1 -> if (keep) Op.STK1 else Op.ST1
            2 -> if (keep) Op.STK2 else Op.ST2
            4 -> if (keep) Op.STK4 else Op.ST4
            else -> if (keep) Op.STK8 else Op.ST8
        }
    }

    private fun incKind(t: Type): Int {
        if (t is F64Type) return Op.KF64
        val it = Types.asInt(t) ?: return Op.K8
        return when (it.size) {
            1 -> if (it.signed) Op.K1S else Op.K1U
            2 -> if (it.signed) Op.K2S else Op.K2U
            4 -> if (it.signed) Op.K4S else Op.K4U
            else -> Op.K8
        }
    }

    /** True when values of this type are represented by their address. */
    private fun isAggregate(t: Type) = t is ArrType || (t is ClassType && t.valueType == null) || t is FuncType

    /** Pushes the value of [e]. */
    fun value(e: Expr) {
        if (e.line > 0) { curFile = e.file; curLine = e.line }
        when (e) {
            is IntLit -> pushInt(e.v)
            is FloatLit -> op(Op.PUSHK, prog.konst(e.v.toRawBits()))
            is StrLit -> op(Op.PUSHI, prog.stringAddr(e.bytes))
            is BinLit -> { val a = prog.binAddr(e.bytes); prog.observer?.binLit(e, a); op(Op.PUSHI, a) }
            is FuncAddr -> op(Op.PUSHK, prog.konst(prog.funcPtr(e.fn)))
            is VarRef -> loadVar(e)
            is Index, is Deref, is MemberAccess -> {
                if (isAggregate(e.type)) addr(e) else { addr(e); op(loadOp(e.type)) }
            }
            is AddrOf -> addr(e.e)
            is Cast -> {
                value(e.e)
                castValue(e.e.type, e.type, e)
            }
            is Unary -> {
                value(e.e)
                when (e.op) {
                    "-" -> if (e.e.type is F64Type) op(Op.FNEG) else op(Op.NEG)
                    "~" -> { if (e.e.type is F64Type) op(Op.F2I); op(Op.COM) }
                    "!" -> if (e.e.type is F64Type) { op(Op.PUSHK, prog.konst(0.0.toRawBits())); op(Op.FEQ) } else op(Op.LNOT)
                }
            }
            is Binary -> binary(e)
            is Chain -> chain(e)
            is Logical -> logical(e)
            is Assign -> assign(e)
            is IncDec -> incDec(e)
            is Call -> call(e)
            is Comma -> {
                for ((i, x) in e.xs.withIndex()) {
                    value(x)
                    if (i < e.xs.size - 1) op(Op.POP)
                }
            }
            is ArgvRef -> err("internal: argv", e)
        }
    }

    private fun pushInt(v: Long) {
        if (v in Int.MIN_VALUE..Int.MAX_VALUE) op(Op.PUSHI, v.toInt()) else op(Op.PUSHK, prog.konst(v))
    }

    private fun loadVar(e: VarRef) {
        val t = e.type
        when (val s = e.sym) {
            is LocalSym -> {
                if (isAggregate(t)) { op(Op.LADDR, s.offset); return }
                val it = Types.asInt(t)
                val o = if (it == null) Op.LLD8 else when (it.size) {
                    1 -> if (it.signed) Op.LLD1S else Op.LLD1U
                    2 -> if (it.signed) Op.LLD2S else Op.LLD2U
                    4 -> if (it.signed) Op.LLD4S else Op.LLD4U
                    else -> Op.LLD8
                }
                op(o, s.offset)
            }
            is GlobalSym -> {
                if (isAggregate(t)) { op(Op.PUSHI, s.addr); return }
                val it = Types.asInt(t)
                val o = if (it == null) Op.GLD8 else when (it.size) {
                    1 -> if (it.signed) Op.GLD1S else Op.GLD1U
                    2 -> if (it.signed) Op.GLD2S else Op.GLD2U
                    4 -> if (it.signed) Op.GLD4S else Op.GLD4U
                    else -> Op.GLD8
                }
                op(o, s.addr)
            }
            is FuncSym -> op(Op.PUSHK, prog.konst(prog.funcPtr(s)))
        }
    }

    /** Pushes the address of an lvalue. */
    fun addr(e: Expr) {
        when (e) {
            is VarRef -> when (val s = e.sym) {
                is LocalSym -> op(Op.LADDR, s.offset)
                is GlobalSym -> op(Op.PUSHI, s.addr)
                is FuncSym -> err("cannot take the address of a function this way", e)
            }
            is Deref -> value(e.e)
            is Index -> {
                value(e.base) // pointer or array address
                val sz = maxOf(e.type.size, 1)
                val ci = ConstFold.int(e.idx)
                if (ci != null) {
                    val off = ci * sz
                    if (off != 0L) { if (off in Int.MIN_VALUE..Int.MAX_VALUE) op(Op.ADDI, off.toInt()) else { pushInt(off); op(Op.ADD) } }
                } else {
                    value(e.idx)
                    if (e.idx.type is F64Type) op(Op.F2I)
                    if (sz != 1) op(Op.MULI, sz)
                    op(Op.ADD)
                }
            }
            is MemberAccess -> {
                if (e.viaPtr) value(e.base) else addr(e.base)
                if (e.offset != 0) op(Op.ADDI, e.offset)
            }
            is Comma -> {
                for ((i, x) in e.xs.withIndex()) {
                    if (i < e.xs.size - 1) { value(x); op(Op.POP) } else addr(x)
                }
            }
            is Cast -> addr(e.e)
            else -> err("expression is not addressable", e)
        }
    }

    /** Arithmetic conversion of the value on the stack from [from] to [to] (no truncation). */
    fun convert(from: Type, to: Type, at: Expr) {
        if (to is F64Type && from !is F64Type) {
            if (isAggregate(from)) err("cannot convert ${from.name} to F64", at)
            op(if (Types.isUnsigned64(from) && from !is PtrType) Op.U2F else Op.I2F)
        } else if (from is F64Type && to !is F64Type && !isAggregate(to)) {
            op(Op.F2I)
        }
    }

    /** Truncates/extends the stack value to the storage width of [t]. */
    private fun narrow(t: Type) {
        val it = Types.asInt(t) ?: return
        when (it.size) {
            1 -> op(if (it.signed) Op.SX1 else Op.ZX1)
            2 -> op(if (it.signed) Op.SX2 else Op.ZX2)
            4 -> op(if (it.signed) Op.SX4 else Op.ZX4)
        }
    }

    private fun castValue(from: Type, to: Type, at: Expr) {
        if (to is F64Type) {
            // HolyC: a postfix (F64) cast of an integer reinterprets the bits.
            if (from !is F64Type) return
            return
        }
        if (from is F64Type) {
            // (I64) on a F64 reinterprets bits as well (use ToI64() to convert)
            narrow(to); return
        }
        narrow(to)
    }

    private fun binary(e: Binary) {
        val lt = e.l.type
        val rt = e.r.type
        val op0 = e.op
        // pointer arithmetic
        if ((op0 == "+" || op0 == "-") && (Types.isPtrLike(lt) || Types.isPtrLike(rt))) {
            if (Types.isPtrLike(lt) && Types.isPtrLike(rt)) {
                value(e.l); value(e.r); op(Op.SUB)
                val sc = Types.scale(lt)
                if (sc != 1) { pushInt(sc.toLong()); op(Op.DIVS) }
                return
            }
            if (Types.isPtrLike(lt)) {
                value(e.l); value(e.r); if (rt is F64Type) op(Op.F2I)
                val sc = Types.scale(lt)
                if (sc != 1) op(Op.MULI, sc)
                op(if (op0 == "+") Op.ADD else Op.SUB)
            } else {
                value(e.l); if (lt is F64Type) op(Op.F2I)
                val sc = Types.scale(rt)
                if (sc != 1) op(Op.MULI, sc)
                value(e.r)
                op(Op.ADD)
            }
            return
        }
        val isF = (lt is F64Type || rt is F64Type || op0 == "`") && op0 !in setOf("&", "|", "^", "<<", ">>")
        value(e.l); if (isF) convert(lt, Types.F64, e) else if (lt is F64Type) op(Op.F2I)
        value(e.r); if (isF) convert(rt, Types.F64, e) else if (rt is F64Type) op(Op.F2I)
        val unsigned = if (op0 in CMP_OPS) Types.isUnsignedAny(lt) || Types.isUnsignedAny(rt) else Types.isUnsigned64(lt) || Types.isUnsigned64(rt)
        op(if (isF) floatOp(op0) else intOp(op0, unsigned, lt))
    }

    private fun floatOp(o: String) = when (o) {
        "+" -> Op.FADD; "-" -> Op.FSUB; "*" -> Op.FMUL; "/" -> Op.FDIV; "%" -> Op.FMOD; "`" -> Op.FPOW
        "==" -> Op.FEQ; "!=" -> Op.FNE; "<" -> Op.FLT; "<=" -> Op.FLE; ">" -> Op.FGT; ">=" -> Op.FGE
        else -> throw IllegalStateException(o)
    }

    private fun intOp(o: String, unsigned: Boolean, lt: Type) = when (o) {
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
        else -> throw IllegalStateException(o)
    }

    private fun chain(e: Chain) {
        val anyF = e.xs.any { it.type is F64Type }
        val anyU = e.xs.any { Types.isUnsignedAny(it.type) }
        val falses = ArrayList<Int>()
        val tmp = allocTemp()
        value(e.xs[0]); if (anyF) convert(e.xs[0].type, Types.F64, e)
        for (i in 1 until e.xs.size) {
            val x = e.xs[i]
            value(x); if (anyF) convert(x.type, Types.F64, e)
            if (i < e.xs.size - 1) op(Op.LSTK8, tmp)
            val o = e.ops[i - 1]
            op(if (anyF) floatOp(o) else intOp(o, anyU, Types.I64))
            if (i < e.xs.size - 1) {
                falses.add(jump(Op.JZ))
                op(Op.LLD8, tmp)
            }
        }
        if (falses.isNotEmpty()) {
            val j = jump(Op.JMP)
            val f = here()
            falses.forEach { patch(it, f) }
            op(Op.PUSHI, 0)
            patch(j, here())
        }
    }

    private fun truth(t: Type) {
        if (t is F64Type) { op(Op.PUSHK, prog.konst(0.0.toRawBits())); op(Op.FNE) } else op(Op.TOBOOL)
    }

    private fun logical(e: Logical) {
        when (e.op) {
            "^^" -> {
                value(e.l); truth(e.l.type)
                value(e.r); truth(e.r.type)
                op(Op.XOR)
            }
            "&&" -> {
                value(e.l); truth(e.l.type)
                val j = jump(Op.JZ)
                value(e.r); truth(e.r.type)
                val je = jump(Op.JMP)
                patch(j, here()); op(Op.PUSHI, 0)
                patch(je, here())
            }
            else -> {
                value(e.l); truth(e.l.type)
                val j = jump(Op.JNZ)
                value(e.r); truth(e.r.type)
                val je = jump(Op.JMP)
                patch(j, here()); op(Op.PUSHI, 1)
                patch(je, here())
            }
        }
    }

    private fun assign(e: Assign) {
        val t = e.target.type
        if (t is ClassType && t.valueType == null) {
            if (e.op != "=") err("compound assignment to a class value", e)
            addr(e.target); value(e.value); op(Op.MEMCPY, t.size)
            addr(e.target)
            return
        }
        if (t is ArrType) err("cannot assign to an array", e)
        val target = e.target
        // fast path: 8-byte local
        if (e.op == "=" && target is VarRef && target.sym is LocalSym && t.size == 8 && !isAggregate(t)) {
            value(e.value); convert(e.value.type, t, e)
            op(Op.LSTK8, (target.sym as LocalSym).offset)
            return
        }
        if (e.op == "=" && hasSideEffects(target)) {
            // TempleOS evaluates the value before the target address, so code like
            // `*dst++=*dst&mask|c;` reads the old pointer (relied on by GrRect).
            value(e.value)
            convert(e.value.type, t, e)
            addr(target)
            op(Op.SWAP)
            op(storeOp(t, keep = true))
            return
        }
        addr(target)
        if (e.op == "=") {
            value(e.value)
            convert(e.value.type, t, e)
            op(storeOp(t, keep = true))
            return
        }
        // compound
        op(Op.DUP)
        op(loadOp(t))
        val bop = e.op.dropLast(1)
        val rt = e.value.type
        if (Types.isPtrLike(t) && (bop == "+" || bop == "-")) {
            value(e.value); if (rt is F64Type) op(Op.F2I)
            val sc = Types.scale(t)
            if (sc != 1) op(Op.MULI, sc)
            op(if (bop == "+") Op.ADD else Op.SUB)
        } else if ((t is F64Type || rt is F64Type) && bop !in setOf("&", "|", "^", "<<", ">>")) {
            convert(t, Types.F64, e)
            value(e.value); convert(rt, Types.F64, e)
            op(floatOp(bop))
            convert(Types.F64, t, e)
        } else {
            value(e.value); if (rt is F64Type) op(Op.F2I)
            op(intOp(bop, Types.isUnsigned64(t) || Types.isUnsigned64(rt), t))
        }
        op(storeOp(t, keep = true))
    }

    private fun incDec(e: IncDec) {
        val t = e.type
        val delta = if (Types.isPtrLike(t)) e.delta * Types.scale(t) else e.delta
        val target = e.target
        if (target is VarRef && target.sym is LocalSym && t.size == 8 && t !is F64Type && !isAggregate(t)) {
            op(Op.LINC8, (target.sym as LocalSym).offset, delta, if (e.post) 1 else 0)
            return
        }
        addr(target)
        op(Op.INC, incKind(t), delta, if (e.post) 1 else 0)
    }

    private fun call(e: Call) {
        val ft = e.ftype
        val params = ft.params
        // Compiler/OptPass012.HC IC_TO_I64/IC_TO_F64: ToI64 of an integer and ToF64 of an F64 drop the
        // argument conversion and the call, leaving the value as it is (GetF64 relies on ToF64(1/4.0))
        val f0 = e.fn
        val a0 = e.args.singleOrNull()
        if (f0 != null && f0.isNative && a0 != null && !isAggregate(a0.type) &&
            (f0.name == "ToF64" && a0.type is F64Type || f0.name == "ToI64" && a0.type !is F64Type)) {
            value(a0)
            return
        }
        if (e.args.size > params.size && !ft.varargs)
            err("too many arguments to ${e.fn?.name ?: "function"}", e)
        // TempleOS evaluates arguments right to left (its compiler pushes them last first; VM probe
        // shared/test-vectors/reference-vm/eval-order.json: f(c++,c++) gets (1,0)): variadic ones, then the
        // fixed ones from the last (defaults included), then REV restores parameter order on the stack
        for (i in params.size until e.args.size) if (e.args[i] == null) err("empty variadic argument", e)
        for (i in params.indices) if (e.args.getOrNull(i) == null && params[i].default == null)
            err("missing argument '${params[i].name}' to ${e.fn?.name ?: "function"}", e)
        val n = maxOf(params.size, e.args.size)
        for (i in e.args.size - 1 downTo params.size) value(e.args[i]!!)
        for (i in params.indices.reversed()) {
            val a = e.args.getOrNull(i)
            val prm = params[i]
            val ex = a ?: prm.default!!
            value(ex)
            if (isAggregate(prm.type) && !isAggregate(ex.type)) {
                // passing an integer where a class is expected: keep raw
            } else convert(ex.type, prm.type, ex)
        }
        if (n > 1) op(Op.REV, n)
        val f = e.fn
        if (f != null) {
            if (f.isNative) op(Op.CALLN, f.nativeIndex, n)
            else {
                if (f.index < 0) prog.addFunc(f)
                op(Op.CALL, f.index, n)
            }
        } else {
            value(e.callee!!)
            op(Op.CALLP, n)
        }
        if (ft.ret is VoidType) return // value is 0 (RET pushes 0)
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

    companion object {
        val CMP_OPS = setOf("<", "<=", ">", ">=", "==", "!=")
    }
}
