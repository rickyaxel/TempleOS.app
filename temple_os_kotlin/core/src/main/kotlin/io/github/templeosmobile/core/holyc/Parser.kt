package io.github.templeosmobile.core.holyc

import io.github.templeosmobile.core.Brand

/**
 * Recursive-descent HolyC parser producing a typed AST. Functions are handed to
 * the code generator as soon as their body is parsed; top-level statements are
 * returned for execution after the unit is compiled.
 */
/** Largest expression tree height accepted (far above real programs). */
const val MAX_EXPR_DEPTH = 5000

/**
 * Statement nesting accepted (blocks, if/while/for bodies), far above real programs. Without an
 * explicit limit, whether deeply nested source overflows the host stack (and is reported) depended
 * on the thread's stack and on how much of the parser the JIT had compiled.
 */
const val MAX_STMT_DEPTH = 1000

class Parser(
    private val prog: Program,
    private val toks: TokenSource,
    private val allowNative: Boolean,
) {
    private var p = 0
    private val tk get() = toks[p]

    // ---- function context
    private var fn: FuncSym? = null
    private var scopes = ArrayList<HashMap<String, LocalSym>>()
    private var frameTop = 0
    private var loopDepth = 0
    private var switchDepth = 0
    private var tmpCounter = 0

    /** Parses a whole unit; returns the top-level statements and their frame size. */
    fun parseTopLevel(): Pair<List<Stmt>, Int> {
        scopes = arrayListOf(HashMap())
        staticLocals.add(HashMap())
        frameTop = 0
        val top = ArrayList<Stmt>()
        while (tk.kind != T.EOF) {
            val s = topLevel() ?: continue
            top.add(s)
        }
        return top to ((frameTop + 7) and 7.inv())
    }

    /**
     * TempleOS JIT semantics: parses top-level items up to and including the
     * next executable statement, so it can run before the rest is compiled.
     * Returns null at end of input.
     */
    fun parseChunk(): Pair<List<Stmt>, Int>? {
        if (tk.kind == T.EOF) return null
        scopes = arrayListOf(HashMap())
        if (staticLocals.isEmpty()) staticLocals.add(HashMap())
        frameTop = 0
        val top = ArrayList<Stmt>()
        while (tk.kind != T.EOF) {
            val s = topLevel() ?: continue
            top.add(s)
            if (executable(s)) break
        }
        return top to ((frameTop + 7) and 7.inv())
    }

    private fun executable(s: Stmt): Boolean = when (s) {
        is GlobalInit -> {
            val e = (s.init as? ExprInit)?.e
            e == null || (ConstFold.int(e) == null && e !is StrLit && ConstFold.float(e) == null)
        }
        is Block -> s.list.any { executable(it) }
        is Nop -> false
        else -> true
    }

    // ================================================================ helpers

    private fun err(msg: String, t: Token = tk): Nothing = throw CompileError(msg, t.file, t.line)
    private fun isP(s: String) = tk.kind == T.PUNCT && tk.text == s
    private fun isId(s: String) = tk.kind == T.IDENT && tk.text == s
    private fun peekP(n: Int, s: String) = p + n < toks.size && toks[p + n].kind == T.PUNCT && toks[p + n].text == s
    private fun accept(s: String): Boolean {
        if (isP(s)) { p++; return true }
        return false
    }
    private fun expect(s: String) {
        if (!accept(s)) err("expected '$s' but found '${tk}'")
    }
    private fun ident(): String {
        if (tk.kind != T.IDENT) err("expected identifier but found '${tk}'")
        return toks[p++].text
    }
    private fun <E : Expr> E.at(t: Token): E {
        // Deep trees (e.g. generated 1+1+...+1 chains) are rejected: the Swift port frees an
        // AST recursively, so an unbounded depth would overflow the host stack there.
        if (depth > MAX_EXPR_DEPTH) err("expression too deeply nested", t)
        file = t.file; line = t.line; return this
    }
    private fun <S : Stmt> S.at(t: Token): S { file = t.file; line = t.line; return this }

    private val modifiers = setOf(
        "public", "static", "extern", "import", "interrupt", "haserrcode", "argpop", "noargpop",
        "reg", "noreg", "native", "_extern", "_import", "_intern",
    )

    private fun typeNamed(n: String): Type? = Types.builtins[n] ?: prog.classes[n]

    private fun isTypeStart(t: Token = tk): Boolean {
        if (t.kind != T.IDENT) return false
        if (t.text == "class" || t.text == "union") return true
        if (t.text in modifiers) return true
        if (lookupLocal(t.text) != null) return false
        return typeNamed(t.text) != null
    }

    private fun lookupLocal(n: String): LocalSym? {
        for (i in scopes.indices.reversed()) scopes[i][n]?.let { return it }
        return null
    }

    // ================================================================ top level

    private fun topLevel(): Stmt? {
        if (accept(";")) return null
        if (isTypeStart()) return declaration(global = true)
        return statement()
    }

    /** Parses `Type a=1, *b, c[3];`, class definitions and function definitions. */
    private fun declaration(global: Boolean): Stmt? {
        val start = tk
        var isNative = false
        var isExtern = false
        var isStatic = false
        while (tk.kind == T.IDENT && tk.text in modifiers) {
            when (tk.text) {
                "native" -> { if (!allowNative) err("'native' is only allowed in the system prelude"); isNative = true }
                "extern", "import" -> isExtern = true
                "static" -> isStatic = true
                "_extern", "_import", "_intern" -> { p++; isExtern = true }
            }
            p++
        }
        // Optional value type for classes: `I64 class X {...}` / `public U32i union Y {...}`
        var valueType: IntType? = null
        if (tk.kind == T.IDENT && (Types.builtins[tk.text] as? IntType) != null && p + 1 < toks.size &&
            (toks[p + 1].text == "class" || toks[p + 1].text == "union")) {
            valueType = Types.builtins[tk.text] as IntType
            p++
        }
        if (isId("class") || isId("union")) {
            val cls = classDef(valueType)
            if (accept(";")) return null
            // TempleOS also accepts a class definition without the closing ';' when the
            // next declaration starts right away (Demo/Graphics/Pick3D.HC)
            if (tk.kind == T.IDENT && (tk.text == "class" || tk.text == "union" || tk.text in modifiers || typeNamed(tk.text) != null)) return null
            // `class X {...} x;` - declarators follow
            return declarators(cls, global, isNative, isExtern, isStatic, start)
        }
        val base = baseType()
        return declarators(base, global, isNative, isExtern, isStatic, start)
    }

    private fun baseType(): Type {
        if (tk.kind != T.IDENT) err("expected type")
        val t = typeNamed(tk.text) ?: err("unknown type '${tk.text}'")
        p++
        return t
    }

    private fun classDef(valueType: IntType?): ClassType {
        val isUnion = tk.text == "union"
        p++
        val name = ident()
        val existing = prog.classes[name]
        val cls = if (existing != null && !existing.defined) existing else ClassType(name, isUnion)
        prog.classes[name] = cls
        cls.valueType = valueType
        if (!isP("{") && !isP(":")) return cls // forward declaration
        if (accept(":")) {
            val b = prog.classes[ident()] ?: err("unknown base class")
            cls.base = b
            for (m in b.members.values) cls.members[m.name] = m
            cls.size = b.size
        }
        expect("{")
        classBody(cls, cls.size, isUnion)
        expect("}")
        cls.defined = true
        return cls
    }

    /** Parses members into [cls] starting at [base]; returns the end offset. */
    private fun classBody(cls: ClassType, base: Int, isUnion: Boolean): Int {
        var off = base
        var maxEnd = base
        while (!isP("}")) {
            if (accept(";")) continue
            if ((isId("union") || isId("class")) && peekP(1, "{")) {
                // anonymous nested union/class: members are placed inline
                val nestedUnion = tk.text == "union"
                p++
                expect("{")
                val end = classBody(cls, off, nestedUnion)
                expect("}")
                accept(";")
                if (isUnion) maxEnd = maxOf(maxEnd, end) else { off = end; maxEnd = off }
                continue
            }
            while (tk.kind == T.IDENT && tk.text in modifiers) p++
            val bt: Type = if (isId("class") || isId("union")) classDef(null) else baseType()
            while (true) {
                val (name, t) = declarator(bt)
                // member meta data: `format "..."`, `data ...` etc.
                var memberFormat: ByteArray? = null
                while (tk.kind == T.IDENT) {
                    val meta = tk.text; p++
                    if (!isP(",") && !isP(";")) {
                        val value = assignExpr()
                        if (meta == "format") memberFormat = (value as? StrLit)?.bytes
                    }
                }
                val mOff = if (isUnion) base else off
                if (name.isNotEmpty()) cls.members[name] = Member(name, t, mOff, memberFormat)
                if (isUnion) maxEnd = maxOf(maxEnd, base + t.size) else { off += t.size; maxEnd = off }
                if (!accept(",")) break
            }
            expect(";")
        }
        cls.size = maxOf(cls.size, maxEnd)
        return maxEnd
    }

    /** Parses pointer stars, the name, array dims and function-pointer syntax. */
    /** Skips register hints: `reg`, `reg R15`, `noreg` (meaningless without x86 codegen). */
    private fun skipRegHints() {
        while (tk.kind == T.IDENT && (tk.text == "reg" || tk.text == "noreg")) {
            p++
            if (tk.kind == T.IDENT && Regex("^R[0-9A-Z]{1,3}$").matches(tk.text) && p + 1 < toks.size && toks[p + 1].kind == T.IDENT) p++
        }
    }

    private fun declarator(base: Type): Pair<String, Type> {
        var t = base
        skipRegHints()
        while (accept("*")) t = PtrType(t)
        skipRegHints()
        if (isP("(") && peekP(1, "*")) {
            // function pointer: Type (*name)(params)
            p += 2
            var extraStars = 0
            while (accept("*")) extraStars++
            val name = if (tk.kind == T.IDENT) ident() else ""
            expect(")")
            expect("(")
            val (params, va) = paramList()
            var ft: Type = PtrType(FuncType(t, params, va))
            repeat(extraStars) { ft = PtrType(ft) }
            return name to ft
        }
        val name = if (tk.kind == T.IDENT && !isTypeStart()) ident() else if (tk.kind == T.IDENT) ident() else ""
        t = arrayDims(t)
        return name to t
    }

    private fun arrayDims(t0: Type): Type {
        val dims = ArrayList<Int>()
        while (accept("[")) {
            if (accept("]")) { dims.add(-1); continue }
            val e = assignExpr()
            dims.add(constInt(e).toInt())
            expect("]")
        }
        // A negative or oversized dimension is a compile error, so every array size is a real Int: the
        // size used to wrap here (and trap the whole app on iOS), letting an initializer write anywhere.
        var total = t0.size.toLong()
        // Validate each inner type before an outer zero dimension can mask its oversized stride.
        for (d in dims.asReversed()) {
            if (d < -1) err("array dimension out of range")
            if (d >= 0) { total *= d; if (total > Int.MAX_VALUE) err("array too large") }
        }
        var t = t0
        for (d in dims.reversed()) t = ArrType(t, d)
        return t
    }

    private fun paramList(): Pair<List<Param>, Boolean> {
        val params = ArrayList<Param>()
        var va = false
        if (accept(")")) return params to false
        while (true) {
            if (accept("...")) { va = true; expect(")"); break }
            while (tk.kind == T.IDENT && tk.text in modifiers) p++
            val bt = baseType()
            val (name, t0) = declarator(bt)
            val t = if (t0 is ArrType) PtrType(t0.elem) else t0
            var def: Expr? = null
            if (accept("=")) {
                def = if (isId("lastclass")) { p++; StrLit(latin1("@lastclass")).also { it.type = Types.U8Ptr } } else assignExpr()
            }
            params.add(Param(name, t, def))
            if (accept(")")) break
            expect(",")
        }
        return params to va
    }

    private fun declarators(base: Type, global: Boolean, isNative: Boolean, isExtern: Boolean, isStatic: Boolean, start: Token): Stmt? {
        val out = ArrayList<Stmt>()
        while (true) {
            val at = tk
            var t = base
            while (accept("*")) t = PtrType(t)
            // function definition or prototype?
            if (tk.kind == T.IDENT && peekP(1, "(") && !(p + 2 < toks.size && toks[p + 2].text == "*")) {
                val name = ident()
                expect("(")
                val (params, va) = paramList()
                val ft = FuncType(t, params, va)
                if (fn != null && !isP("{")) {
                    // prototype inside a function body: ignore
                    expect(";"); return null
                }
                funcDef(name, ft, isNative, at)
                return if (out.isEmpty()) null else Block(out).at(start)
            }
            val (name, dt0) = declarator(t)
            if (name.isEmpty()) err("expected a variable name")
            var dt = dt0
            var init: Init? = null
            if (accept("=")) init = initializer()
            // infer [] size from initializer
            if (dt is ArrType && dt.count < 0) {
                val n = when (init) {
                    is ListInit -> init.items.size
                    is ExprInit -> ((init.e as? StrLit)?.bytes?.size?.plus(1)) ?: 0
                    null -> 0
                }
                dt = ArrType(dt.elem, n)
            }
            if (global || isStatic) {
                val g = declareGlobal(name, dt, isExtern, at)
                if (init != null) out.add(GlobalInit(g, init).at(at))
            } else {
                val l = declareLocal(name, dt, at)
                out.add(LocalInit(l, init).at(at))
            }
            if (!accept(",")) break
            if (isP(";")) break // `I64 a,b,;` (Demo/Graphics/Life.HC)
        }
        expect(";")
        return when (out.size) { 0 -> null; 1 -> out[0]; else -> Block(out).at(start) }
    }

    private fun initializer(): Init {
        if (accept("{")) {
            val items = ArrayList<Init>()
            while (!isP("}")) {
                items.add(initializer())
                if (!accept(",")) break
            }
            expect("}")
            return ListInit(items)
        }
        return ExprInit(assignExpr())
    }

    private fun declareGlobal(name: String, t: Type, isExtern: Boolean, at: Token): GlobalSym {
        val old = prog.globals[name]
        if (old is GlobalSym) {
            if (isExtern || old.type.size == t.size) return old
        }
        if (fn != null) {
            // static local: lives in global storage, visible only in this function
            val g = GlobalSym(name, t, prog.allocGlobal(t.size))
            staticLocals.last()[name] = g
            return g
        }
        val g = GlobalSym(name, t, prog.allocGlobal(maxOf(t.size, 1)))
        prog.globals[name] = g
        return g
    }

    private val staticLocals = ArrayList<HashMap<String, GlobalSym>>()

    private fun declareLocal(name: String, t: Type, at: Token): LocalSym {
        val size = maxOf(t.size, 1)
        frameTop = (frameTop + 7) and 7.inv()
        val l = LocalSym(name, t, frameTop)
        frameTop += size
        scopes.last()[name] = l
        return l
    }

    private fun funcDef(name: String, ft: FuncType, isNative: Boolean, at: Token) {
        val old = prog.globals[name] as? FuncSym
        val f = if (old != null && !old.defined && !old.isNative) {
            old.type = ft; old
        } else if (old != null && old.defined && !isP("{")) {
            expect(";"); return
        } else {
            FuncSym(name, ft).also { prog.addFunc(it) }
        }
        f.file = at.file; f.line = at.line
        prog.globals[name] = f
        if (isNative) {
            expect(";")
            prog.bindNative(f)
            return
        }
        if (accept(";")) return // prototype
        if (!isP("{")) err("expected function body")
        // parse body
        val saved = Triple(fn, scopes, frameTop)
        fn = f
        scopes = arrayListOf(HashMap())
        staticLocals.add(HashMap())
        frameTop = 0
        val offs = IntArray(ft.params.size)
        for ((i, prm) in ft.params.withIndex()) {
            frameTop = (frameTop + 7) and 7.inv()
            offs[i] = frameTop
            if (prm.name.isNotEmpty()) scopes[0][prm.name] = LocalSym(prm.name, prm.type, frameTop)
            frameTop += 8
        }
        f.paramOffsets = offs
        if (ft.varargs) {
            f.argcSlot = frameTop; scopes[0]["argc"] = LocalSym("argc", Types.I64, frameTop); frameTop += 8
            f.argvSlot = frameTop; scopes[0]["argv"] = LocalSym("argv", PtrType(Types.I64), frameTop); frameTop += 8
        }
        f.defined = true
        val body = block()
        f.frameSize = (frameTop + 7) and 7.inv()
        prog.codegen.compileFunction(f, body)
        fn = saved.first; scopes = saved.second; frameTop = saved.third
        staticLocals.removeAt(staticLocals.size - 1)
    }

    // ================================================================ statements

    private fun block(): Block {
        val at = tk
        expect("{")
        scopes.add(HashMap())
        val list = ArrayList<Stmt>()
        while (!isP("}")) {
            if (tk.kind == T.EOF) err("unexpected end of file in block", at)
            statementOrDecl()?.let { list.add(it) }
        }
        p++
        scopes.removeAt(scopes.size - 1)
        return Block(list).at(at)
    }

    private fun statementOrDecl(): Stmt? {
        if (isTypeStart() && !(tk.kind == T.IDENT && peekP(1, "(") && typeNamed(tk.text) == null && tk.text !in modifiers)) {
            if (fn == null) return declaration(global = true)
            return declaration(global = false)
        }
        return statement()
    }

    private var stmtDepth = 0

    private fun statement(): Stmt? {
        try {
            if (++stmtDepth > MAX_STMT_DEPTH) err(Program.DEEP_NESTING)
            return statement0()
        } finally { stmtDepth-- }
    }

    private fun statement0(): Stmt? {
        val at = tk
        if (tk.kind == T.PUNCT) {
            when (tk.text) {
                "{" -> return block()
                ";" -> { p++; return Nop }
            }
        }
        if (tk.kind == T.IDENT) {
            when (tk.text) {
                "if" -> {
                    p++; expect("("); val c = expr(); expect(")")
                    val t = statementOrDecl() ?: Nop
                    val f = if (isId("else")) { p++; statementOrDecl() ?: Nop } else null
                    return If(c, t, f).at(at)
                }
                "while" -> {
                    p++; expect("("); val c = expr(); expect(")")
                    loopDepth++
                    val b = statementOrDecl() ?: Nop
                    loopDepth--
                    return While(c, b).at(at)
                }
                "do" -> {
                    p++
                    loopDepth++
                    val b = statementOrDecl() ?: Nop
                    loopDepth--
                    if (!isId("while")) err("expected 'while'")
                    p++; expect("("); val c = expr(); expect(")"); accept(";")
                    return DoWhile(b, c).at(at)
                }
                "for" -> {
                    p++; expect("(")
                    scopes.add(HashMap())
                    val init: Stmt? = if (isP(";")) { p++; null } else if (isTypeStart()) declaration(false) else ExprStmt(expr()).also { expect(";") }
                    val c = if (isP(";")) null else expr()
                    expect(";")
                    val step = if (isP(")")) null else expr()
                    expect(")")
                    loopDepth++
                    val b = statementOrDecl() ?: Nop
                    loopDepth--
                    scopes.removeAt(scopes.size - 1)
                    return For(init, c, step, b).at(at)
                }
                "switch" -> return switchStmt()
                "break" -> { p++; expect(";"); return Break().at(at) }
                "continue" -> { p++; expect(";"); return Continue().at(at) }
                "return" -> {
                    p++
                    if (accept(";")) return Return(null).at(at)
                    val e = expr(); expect(";")
                    return Return(e).at(at)
                }
                "goto" -> { p++; val l = ident(); expect(";"); return Goto(l).at(at) }
                "try" -> {
                    p++
                    val body = statementOrDecl() ?: Nop
                    if (!isId("catch")) err("expected 'catch'")
                    p++
                    val h = statementOrDecl() ?: Nop
                    return Try(body, h).at(at)
                }
                "lock" -> { p++; return statementOrDecl() }
                // x86 instructions TempleOS allows as statements; no effect in the sandbox
                "CLI", "STI", "PUSHFD", "POPFD", "PAUSE", "CLD", "STD", "WBINVD", "INVLPG" ->
                    if (!peekP(1, "(") && !peekP(1, "=")) { p++; accept(";"); return null }
                "no_warn" -> { while (!isP(";")) p++; p++; return null }
                "asm" -> err("inline x86 assembly (asm {}) is not supported by ${Brand.APP_NAME}")
                "case", "default", "start", "end" -> if (switchDepth > 0) return switchLabel()
            }
            // label?
            if (peekP(1, ":") && scopes.isNotEmpty()) {
                val name = ident(); p++
                return Label(name).at(at)
            }
        }
        // String statement: "fmt",args;  or  "" fmt,args;
        if (tk.kind == T.STR) {
            val printFn = prog.globals["Print"] as? FuncSym ?: err("Print is not available")
            val fmt = tk
            p++
            val args = ArrayList<Expr?>()
            if (fmt.bytes!!.isEmpty() && !isP(",") && !isP(";")) {
                args.add(assignExpr())
            } else {
                var b = fmt.bytes!!
                // adjacent literal concatenation
                while (tk.kind == T.STR) { b += tk.bytes!!; p++ }
                args.add(StrLit(b).also { it.type = Types.U8Ptr }.at(fmt))
            }
            while (accept(",")) args.add(assignExpr())
            expect(";")
            return ExprStmt(Call(printFn, null, printFn.ftype, args).also { it.type = Types.I64 }.at(at)).at(at)
        }
        // '' expr; prints expr as characters: an empty char constant "signals PutChars with
        // variable" (Compiler/PrsExp.HC PrsFunCall; Doc/HolyC.DD: '' drv;)
        if (tk.kind == T.CHAR && tk.charLen == 0 && !peekP(1, ";")) {
            val putChars = prog.globals["PutChars"] as? FuncSym ?: err("PutChars is not available")
            p++
            val args = ArrayList<Expr?>()
            args.add(assignExpr())
            expect(";")
            return ExprStmt(Call(putChars, null, putChars.ftype, args).also { it.type = Types.U0 }.at(at)).at(at)
        }
        if (tk.kind == T.CHAR && (peekP(1, ";") || peekP(1, ","))) {
            val putChars = prog.globals["PutChars"] as? FuncSym ?: err("PutChars is not available")
            val args = ArrayList<Expr?>()
            args.add(IntLit(tk.ival).also { it.type = Types.I64 }.at(tk))
            p++
            while (accept(",")) {
                args.clear(); args.add(assignExpr())
            }
            expect(";")
            return ExprStmt(Call(putChars, null, putChars.ftype, args).also { it.type = Types.U0 }.at(at)).at(at)
        }
        val e = expr()
        expect(";")
        return ExprStmt(e).at(at)
    }

    private fun switchStmt(): Stmt {
        val at = tk
        p++
        val unchecked = isP("[")
        if (!accept("(")) expect("[")
        val e = expr()
        if (unchecked) expect("]") else expect(")")
        expect("{")
        switchDepth++
        scopes.add(HashMap())
        val body = ArrayList<Stmt>()
        nextCase.add(0L)
        while (!isP("}")) {
            if (tk.kind == T.EOF) err("unexpected end of file in switch", at)
            statementOrDecl()?.let { body.add(it) }
        }
        p++
        nextCase.removeAt(nextCase.size - 1)
        scopes.removeAt(scopes.size - 1)
        switchDepth--
        return Switch(e, body, unchecked).at(at)
    }

    private val nextCase = ArrayList<Long>()

    private fun switchLabel(): Stmt {
        val at = tk
        val w = ident()
        when (w) {
            "default" -> { expect(":"); return CaseLabel(0, 0, true).at(at) }
            "start" -> { expect(":"); return SubStart().at(at) }
            "end" -> { expect(":"); return SubEnd().at(at) }
        }
        // case
        if (accept(":")) {
            val v = nextCase.last()
            nextCase[nextCase.size - 1] = v + 1
            return CaseLabel(v, v, false).at(at)
        }
        val lo = constInt(assignExpr())
        var hi = lo
        if (accept("...")) hi = constInt(assignExpr())
        expect(":")
        nextCase[nextCase.size - 1] = hi + 1
        return CaseLabel(lo, hi, false).at(at)
    }

    // ================================================================ expressions

    fun expr(): Expr {
        val at = tk
        val first = assignExpr()
        if (!isP(",")) return first
        val xs = arrayListOf(first)
        while (accept(",")) xs.add(assignExpr())
        return Comma(xs).also { it.type = xs.last().type }.at(at)
    }

    private val assignOps = setOf("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=")

    fun assignExpr(): Expr {
        val at = tk
        val l = binary(1)
        if (tk.kind == T.PUNCT && tk.text in assignOps) {
            val op = tk.text
            p++
            val r = assignExpr()
            checkLvalue(l)
            return Assign(op, l, r).also { it.type = l.type }.at(at)
        }
        return l
    }

    private fun prec(t: Token): Int {
        if (t.kind != T.PUNCT) return -1
        return when (t.text) {
            "`", ">>", "<<" -> 11
            "*", "/", "%" -> 10
            "&" -> 9
            "^" -> 8
            "|" -> 7
            "+", "-" -> 6
            "<", ">", "<=", ">=" -> 5
            "==", "!=" -> 4
            "&&" -> 3
            "^^" -> 2
            "||" -> 1
            else -> -1
        }
    }

    private fun binary(minPrec: Int): Expr {
        var l = unary()
        while (true) {
            val pr = prec(tk)
            if (pr < minPrec) return l
            val at = tk
            val op = tk.text
            p++
            if (pr == 5 || pr == 4) {
                // Chained comparisons: any comparison following another chains, e.g.
                // 2<3==1 is 2<3 && 3==1 (Compiler/PrsExp.HC ICF_PUSH_CMP; all six are IST_CMP).
                val ops = arrayListOf(op)
                val xs = arrayListOf(l, binary(pr + 1))
                while (prec(tk).let { (it == 4 || it == 5) && it >= minPrec }) {
                    val opr = prec(tk); ops.add(tk.text); p++
                    xs.add(binary(opr + 1))
                }
                l = if (ops.size == 1) mkBinary(op, xs[0], xs[1], at) else Chain(ops, xs).also { it.type = Types.I64 }.at(at)
                continue
            }
            if (op == "`") { l = mkBinary(op, l, powerOperand(), at); continue }
            val r = binary(pr + 1)
            l = if (pr <= 3) Logical(op, l, r).also { it.type = Types.I64 }.at(at) else mkBinary(op, l, r, at)
        }
    }

    /** Right operand of ` : right associative among ` only (Compiler/CInit.HC ASSOCF_RIGHT). */
    private fun powerOperand(): Expr {
        val at = tk
        val b = binary(12)
        if (tk.kind == T.PUNCT && tk.text == "`") { p++; return mkBinary("`", b, powerOperand(), at) }
        return b
    }

    fun mkBinary(op: String, l: Expr, r: Expr, at: Token): Expr {
        val lt = l.type
        val rt = r.type
        val type: Type = when (op) {
            "<", ">", "<=", ">=", "==", "!=" -> Types.I64
            "+", "-" -> when {
                Types.isPtrLike(lt) && Types.isPtrLike(rt) && op == "-" -> Types.I64
                Types.isPtrLike(lt) -> decay(lt)
                Types.isPtrLike(rt) && op == "+" -> decay(rt)
                lt is F64Type || rt is F64Type -> Types.F64
                Types.isUnsigned64(lt) || Types.isUnsigned64(rt) -> Types.U64
                else -> Types.I64
            }
            "`" -> Types.F64 // always F64 (Compiler/OptPass012.HC IC_POWER)
            "*", "/", "%" -> when {
                lt is F64Type || rt is F64Type -> Types.F64
                Types.isUnsigned64(lt) || Types.isUnsigned64(rt) -> Types.U64
                else -> Types.I64
            }
            "<<", ">>" -> if (lt is F64Type) Types.I64 else if (Types.isUnsigned64(lt)) Types.U64 else Types.I64
            else -> if (Types.isUnsigned64(lt) || Types.isUnsigned64(rt)) Types.U64 else Types.I64 // & | ^
        }
        if (lt is ClassType && lt.valueType == null || rt is ClassType && rt.valueType == null)
            err("invalid operands to '$op' (class value)", at)
        return Binary(op, l, r).also { it.type = type }.at(at)
    }

    private fun decay(t: Type): Type = if (t is ArrType) PtrType(t.elem) else t

    private fun unary(): Expr {
        val at = tk
        if (tk.kind == T.PUNCT) {
            when (tk.text) {
                "-" -> {
                    p++
                    var e = unary()
                    // -x`y is -(x`y) (Compiler/PrsExp.HC PE_DO_UNARY_OP special case)
                    if (tk.kind == T.PUNCT && tk.text == "`") { val pa = tk; p++; e = mkBinary("`", e, powerOperand(), pa) }
                    if (e is IntLit) return IntLit(-e.v).also { it.type = Types.I64 }.at(at)
                    if (e is FloatLit) return FloatLit(-e.v).also { it.type = Types.F64 }.at(at)
                    return Unary("-", e).also { it.type = if (e.type is F64Type) Types.F64 else if (Types.isUnsigned64(e.type)) Types.U64 else Types.I64 }.at(at)
                }
                "+" -> { p++; return unary() }
                "!" -> { p++; val e = unary(); return Unary("!", e).also { it.type = Types.I64 }.at(at) }
                "~" -> { p++; val e = unary(); return Unary("~", e).also { it.type = if (Types.isUnsigned64(e.type)) Types.U64 else Types.I64 }.at(at) }
                "*" -> {
                    p++
                    val e = unary()
                    return deref(e, at)
                }
                "&" -> {
                    p++
                    // &Func => function address
                    if (tk.kind == T.IDENT && lookupLocal(tk.text) == null) {
                        val f = prog.globals[tk.text] as? FuncSym
                        if (f != null && !peekP(1, "(")) {
                            p++
                            return FuncAddr(f).also { it.type = PtrType(f.ftype) }.at(at)
                        }
                    }
                    val e = unary()
                    if (e is Call && e.args.isEmpty() && e.fn != null) // &Func parsed as no-paren call
                        return FuncAddr(e.fn).also { it.type = PtrType(e.fn.ftype) }.at(at)
                    if (e is FuncAddr) return e
                    checkLvalue(e)
                    val t = when (val et = e.type) { is ArrType -> PtrType(et.elem); else -> PtrType(et) }
                    return AddrOf(e).also { it.type = t }.at(at)
                }
                "++", "--" -> {
                    val d = if (tk.text == "++") 1 else -1
                    p++
                    val e = unary()
                    checkLvalue(e)
                    return IncDec(e, d, false).also { it.type = e.type }.at(at)
                }
            }
        }
        if (tk.kind == T.IDENT && (tk.text == "sizeof" || tk.text == "offset")) return sizeofExpr()
        return postfix(primary())
    }

    private fun deref(e: Expr, at: Token): Expr {
        val t = e.type
        // On TempleOS (reference VM) a non-pointer is used as an address and read with its own type:
        // *I64 reads 8 bytes, *U8 one, *I32 four; *F64 uses the F64's bits. A class variable's value
        // is its first 8 bytes, so *classvar reads the I64 those bytes point to (ToTheFront's
        // while (tmpi!=*indirect_head)). docs/fidelity-audit/data/vm-observations.json
        if (t is ClassType && t.valueType == null) {
            val first = MemberAccess(e, 0, false).also { it.type = Types.I64 }.at(at)
            return Deref(first).also { it.type = Types.I64 }.at(at)
        }
        val target = when (t) {
            is PtrType -> t.target
            is ArrType -> t.elem
            is IntType, is F64Type -> t
            is ClassType -> t.valueType!!
            else -> err("cannot dereference ${t.name}", at)
        }
        if (target is FuncType) return e // (*fp)(...) == fp(...)
        return Deref(e).also { it.type = target }.at(at)
    }

    private fun sizeofExpr(): Expr {
        val at = tk
        val isOffset = tk.text == "offset"
        p++
        val paren = accept("(")
        val result: Long
        if (tk.kind == T.IDENT && typeNamed(tk.text) != null && lookupLocal(tk.text) == null && prog.globals[tk.text] !is GlobalSym) {
            var t: Type = typeNamed(ident())!!
            if (accept(".")) {
                val mname = ident()
                val cls = t as? ClassType ?: err("not a class", at)
                val m = cls.find(mname) ?: err("no member '$mname' in ${cls.name}", at)
                result = if (isOffset) m.offset.toLong() else m.type.size.toLong()
            } else {
                while (accept("*")) t = PtrType(t)
                result = t.size.toLong()
            }
        } else {
            if (isOffset) err("offset() needs Class.member", at)
            val e = if (paren) expr() else unary()
            result = e.type.size.toLong()
        }
        if (paren) expect(")")
        return IntLit(result).also { it.type = Types.I64 }.at(at)
    }

    private fun primary(): Expr {
        val at = tk
        when (tk.kind) {
            T.INT -> { p++; return IntLit(at.ival).also { it.type = if (at.ival < 0) Types.U64 else Types.I64 }.at(at) }
            T.CHAR -> { p++; return IntLit(at.ival).also { it.type = Types.I64 }.at(at) }
            T.FLOAT -> { p++; return FloatLit(at.fval).also { it.type = Types.F64 }.at(at) }
            T.STR -> {
                var b = at.bytes!!
                p++
                while (tk.kind == T.STR) { b += tk.bytes!!; p++ }
                return StrLit(b).also { it.type = Types.U8Ptr }.at(at)
            }
            T.INS_BIN -> { p++; return BinLit(at.bytes!!).also { it.type = Types.U8Ptr }.at(at) }
            T.PUNCT -> {
                if (accept("(")) {
                    val e = expr()
                    expect(")")
                    return e
                }
                err("unexpected '${tk}'")
            }
            T.IDENT -> {
                val name = tk.text
                p++
                lookupLocal(name)?.let { return VarRef(it).also { r -> r.type = it.type }.at(at) }
                staticLocals.lastOrNull()?.get(name)?.let { return VarRef(it).also { r -> r.type = it.type }.at(at) }
                when (val g = prog.globals[name]) {
                    is FuncSym -> {
                        if (isP("(")) return callArgs(g, null, g.ftype, at)
                        return Call(g, null, g.ftype, emptyList()).also { it.type = g.ftype.ret }.at(at)
                    }
                    is GlobalSym -> { if(name=="acd") prog.requireService("dictionary");return VarRef(g).also { it.type = g.type }.at(at) }
                    else -> {}
                }
                when (name) {
                    "lastclass" -> return StrLit(latin1("@lastclass")).also { it.type = Types.U8Ptr }.at(at)
                    "TRUE" -> return IntLit(1).also { it.type = Types.I64 }.at(at)
                    "FALSE", "NULL" -> return IntLit(0).also { it.type = Types.I64 }.at(at)
                }
                err("undefined identifier '$name'", at)
            }
            T.EOF -> err("unexpected end of file")
        }
    }

    private fun postfix(e0: Expr): Expr {
        var e = e0
        while (true) {
            val at = tk
            if (tk.kind != T.PUNCT) return e
            when (tk.text) {
                "[" -> {
                    p++
                    val idx = expr()
                    expect("]")
                    val bt = e.type
                    val elem = when (bt) {
                        is ArrType -> bt.elem
                        is PtrType -> bt.target
                        else -> err("cannot index ${bt.name}", at)
                    }
                    e = Index(e, idx).also { it.type = elem }.at(at)
                }
                ".", "->" -> {
                    val arrow = tk.text == "->"
                    p++
                    val mname = ident()
                    e = member(e, mname, arrow, at)
                }
                "(" -> {
                    // postfix type cast?
                    if (p + 1 < toks.size && isTypeStart(toks[p + 1]) && toks[p + 1].text !in modifiers) {
                        p++
                        var t = baseType()
                        while (accept("*")) t = PtrType(t)
                        expect(")")
                        e = Cast(e).also { it.type = t }.at(at)
                        continue
                    }
                    val ft = funcTypeOf(e.type) ?: err("called object is not a function", at)
                    e = callArgs(null, e, ft, at)
                }
                "++", "--" -> {
                    val d = if (tk.text == "++") 1 else -1
                    p++
                    checkLvalue(e)
                    e = IncDec(e, d, true).also { it.type = e.type }.at(at)
                }
                else -> return e
            }
        }
    }

    private fun funcTypeOf(t: Type): FuncType? = when (t) {
        is FuncType -> t
        is PtrType -> t.target as? FuncType ?: ((t.target as? PtrType)?.target as? FuncType)
        else -> null
    }

    private fun member(base: Expr, name: String, arrow: Boolean, at: Token): Expr {
        var b = base
        var bt = b.type
        if (arrow) {
            bt = when (bt) {
                is PtrType -> bt.target
                is ArrType -> bt.elem
                else -> err("'->' on non-pointer ${bt.name}", at)
            }
        }
        if (bt is ClassType) {
            val m = bt.find(name) ?: err("no member '$name' in ${bt.name}", at)
            if (!arrow) b = lvalueOrTemp(b, at)
            return MemberAccess(b, m.offset, arrow).also { it.type = m.type }.at(at)
        }
        val it0 = Types.asInt(bt) ?: (if (bt is F64Type) Types.I64 else null) ?: err("member '$name' on ${bt.name}", at)
        val sub = Types.intSubMember(it0 as IntType, name) ?: err("no member '$name' in ${bt.name}", at)
        if (!arrow) b = lvalueOrTemp(b, at)
        return MemberAccess(b, 0, arrow).also { it.type = sub }.at(at)
    }

    /** Sub-member access needs an address; spill rvalues into a hidden temporary. */
    private fun lvalueOrTemp(e: Expr, at: Token): Expr {
        if (isLvalue(e)) return e
        val name = "\$tmp${tmpCounter++}"
        val ref: Expr = if (scopes.isNotEmpty()) {
            val l = declareLocal(name, e.type, at)
            VarRef(l).also { it.type = e.type }
        } else {
            val g = GlobalSym(name, e.type, prog.allocGlobal(maxOf(e.type.size, 8)))
            VarRef(g).also { it.type = e.type }
        }
        ref.at(at)
        return Comma(listOf(Assign("=", ref, e).also { it.type = e.type }.at(at), ref)).also { it.type = e.type }.at(at)
    }

    private fun isLvalue(e: Expr): Boolean = when (e) {
        is VarRef -> e.sym !is FuncSym
        is Index, is Deref -> true
        is MemberAccess -> true
        is Comma -> isLvalue(e.xs.last())
        is Cast -> isLvalue(e.e)
        else -> false
    }

    private fun checkLvalue(e: Expr) {
        if (!isLvalue(e)) throw CompileError("expression is not assignable", e.file, e.line)
    }

    private fun callArgs(fsym: FuncSym?, callee: Expr?, ft: FuncType, at: Token): Expr {
        expect("(")
        val args = ArrayList<Expr?>()
        if (!accept(")")) {
            while (true) {
                if (isP(",")) args.add(null)
                else if (isP(")")) args.add(null)
                else args.add(assignExpr())
                if (accept(")")) break
                expect(",")
            }
        }
        // TempleOS lastclass defaults use the preceding argument's static class type.
        for ((i, param) in ft.params.withIndex()) {
            if (args.getOrNull(i) != null || (param.default as? StrLit)?.bytes?.contentEquals(latin1("@lastclass")) != true) continue
            val previous = args.getOrNull(i - 1)?.type
            val type = if (previous is PtrType) previous.target else previous
            while (args.size <= i) args.add(null)
            args[i] = StrLit(latin1((type as? ClassType)?.name ?: "")).also { it.type = Types.U8Ptr }.at(at)
        }
        return Call(fsym, callee, ft, args).also { it.type = ft.ret }.at(at)
    }

    // ================================================================ constants

    /** Constant value of [e]; like TempleOS JIT mode, non-constant expressions are run at compile time. */
    fun constInt(e: Expr): Long = ConstFold.int(e) ?: prog.evalAtCompileTime?.invoke(e)
        ?: throw CompileError("constant expression expected", e.file, e.line)
}

/** Compile-time folding of integer constant expressions. */
object ConstFold {
    fun int(e: Expr): Long? = when (e) {
        is IntLit -> e.v
        is FloatLit -> e.v.toLong()
        is Unary -> int(e.e)?.let { v -> when (e.op) { "-" -> -v; "~" -> v.inv(); else -> if (v == 0L) 1 else 0 } }
        is Cast -> int(e.e)
        is Binary -> {
            val l = int(e.l); val r = int(e.r)
            if (l == null || r == null || e.type is F64Type || e.l.type is F64Type || e.r.type is F64Type || Types.isPtrLike(e.l.type) || Types.isPtrLike(e.r.type)) null
            else when (e.op) {
                "+" -> l + r; "-" -> l - r; "*" -> l * r
                "/" -> if (r == 0L) null else l / r
                "%" -> if (r == 0L) null else l % r
                "&" -> l and r; "|" -> l or r; "^" -> l xor r
                "<<" -> l shl r.toInt(); ">>" -> l shr r.toInt()
                "<" -> b(l < r); ">" -> b(l > r); "<=" -> b(l <= r); ">=" -> b(l >= r)
                "==" -> b(l == r); "!=" -> b(l != r)
                "`" -> { var x = 1L; repeat(r.toInt().coerceAtLeast(0)) { x *= l }; x }
                else -> null
            }
        }
        is Logical -> {
            val l = int(e.l); val r = int(e.r)
            if (l == null || r == null) null else when (e.op) {
                "&&" -> b(l != 0L && r != 0L); "||" -> b(l != 0L || r != 0L); else -> b((l != 0L) != (r != 0L))
            }
        }
        else -> null
    }

    fun float(e: Expr): Double? = when (e) {
        is FloatLit -> e.v
        is IntLit -> e.v.toDouble()
        is Unary -> if (e.op == "-") float(e.e)?.let { -it } else null
        is Binary -> {
            val l = float(e.l); val r = float(e.r)
            if (l == null || r == null) null else when (e.op) {
                "+" -> l + r; "-" -> l - r; "*" -> l * r; "/" -> l / r; else -> null
            }
        }
        else -> null
    }

    private fun b(v: Boolean) = if (v) 1L else 0L
}
