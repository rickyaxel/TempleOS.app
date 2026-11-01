package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.holyc.CompileError
import io.github.templeosmobile.core.holyc.FuncSym
import io.github.templeosmobile.core.holyc.FuncType
import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.PtrType
import io.github.templeosmobile.core.holyc.Sym

/** What the parser may ask about names (answered from the kernel's symbol tables, and recorded for the cache). */
interface DynScope {
    /** The compiler's global symbol (function or variable) named [name], or null. */
    fun symbol(name: String): Sym?
    fun isClassName(name: String): Boolean
    /** True when a TempleOS header `#define`s [name] (outside the subset unless it is in [DynMacros]). */
    fun isKnownMacro(name: String): Boolean
}

/**
 * Recursive-descent parser for a sequence of HolyC expression statements, producing the typed AST.
 *
 * It is the app's compiler front end (holyc/Parser.kt) restricted to what can appear at the top level of
 * `ExePrint` text, rewritten for the engine: the same precedence climber (`` ` ``, `<<` and `>>` bind
 * tightest, then `* / %`, `&`, `^`, `|`, `+ -`, comparisons, `==`/`!=`, `&&`, `^^`, `||`), the same
 * right-associative `` ` `` and the `-x`y` rule, chained comparisons, postfix casts, the same token
 * lookahead (so a lexer error is reported at the same point) and the same error messages. Constructs the
 * engine does not evaluate are parsed as the compiler parses them and become [DUnsupported] nodes, so that
 * syntax errors keep the compiler's precedence over "outside the subset".
 *
 * Recursion is bounded: [DynLimits.MAX_PARSE_NESTING] nested sub-expressions while parsing, and
 * [DynLimits.MAX_AST_HEIGHT] for the finished tree (left-associative operator sequences are [DFold]s
 * and do not deepen the tree).
 */
class DynParser(private val lx: DynLexer, private val scope: DynScope, private val file: String) {
    private var p = 0
    private val tk: DToken get() = lx[p]
    private var nesting = 0

    /** The next chunk (TempleOS JIT order), or null at the end of the text. */
    fun parseChunk(): DChunk? {
        if (tk.kind == DTok.EOF) return null
        while (tk.kind != DTok.EOF) {
            if (accept(";")) continue // empty statements (Parser.topLevel)
            return statement()
        }
        return DEmpty
    }

    // ================================================================ helpers

    private fun err(msg: String, t: DToken = tk): Nothing = throw CompileError(msg, file, t.line)
    private fun outside(what: String, line: Int): Nothing = throw DynExpr.outside(what, file, line)
    private fun isP(s: String) = tk.kind == DTok.PUNCT && tk.text == s
    private fun peekP(n: Int, s: String) = p + n < lx.size && lx[p + n].kind == DTok.PUNCT && lx[p + n].text == s
    private fun accept(s: String): Boolean { if (isP(s)) { p++; return true }; return false }
    private fun expect(s: String) { if (!accept(s)) err("expected '$s' but found '$tk'") }
    private fun ident(): String {
        if (tk.kind != DTok.IDENT) err("expected identifier but found '$tk'")
        return lx[p++].text
    }

    private fun <N : DNode> N.ok(): N {
        if (height > DynLimits.MAX_AST_HEIGHT) throw DynExpr.limit("nested deeper than ${DynLimits.MAX_AST_HEIGHT} levels", file, line)
        return this
    }

    private inline fun <T> nested(block: () -> T): T {
        if (++nesting > DynLimits.MAX_PARSE_NESTING) { throw DynExpr.limit("nested deeper than ${DynLimits.MAX_PARSE_NESTING} sub-expressions", file, tk.line) }
        try { return block() } finally { nesting-- }
    }

    private fun isTypeName(n: String) = DType.builtins.containsKey(n) || scope.isClassName(n)

    private fun isTypeStart(t: DToken): Boolean {
        if (t.kind != DTok.IDENT) return false
        if (t.text == "class" || t.text == "union") return true
        if (t.text in MODIFIERS) return true
        return isTypeName(t.text)
    }

    // ================================================================ statements (Parser.topLevel / statement0)

    private fun statement(): DChunk {
        val at = tk
        if (isTypeStart(at)) outside("a declaration", at.line)
        if (at.kind == DTok.PUNCT && at.text == "{") outside("a block { }", at.line)
        if (at.kind == DTok.IDENT) {
            when (at.text) {
                "if", "while", "do", "for", "switch", "break", "continue", "return", "goto", "try", "lock", "no_warn" ->
                    outside("the statement '${at.text}'", at.line)
                "CLI", "STI", "PUSHFD", "POPFD", "PAUSE", "CLD", "STD", "WBINVD", "INVLPG" ->
                    if (!peekP(1, "(") && !peekP(1, "=")) outside("the x86 instruction '${at.text}'", at.line)
                "asm" -> err("inline x86 assembly (asm {}) is not supported by ${Brand.APP_NAME}")
            }
            if (peekP(1, ":")) outside("a label", at.line)
        }
        if (at.kind == DTok.STR) outside("a string statement (Print)", at.line)
        if (at.kind == DTok.CHAR && at.charLen == 0 && !peekP(1, ";")) outside("a character output statement", at.line)
        if (at.kind == DTok.CHAR && (peekP(1, ";") || peekP(1, ","))) outside("a character output statement", at.line)
        val e = expr()
        expect(";")
        return DStmt(e, at.line)
    }

    // ================================================================ expressions

    fun expr(): DNode {
        val at = tk
        val first = assignExpr()
        if (!isP(",")) return first
        val xs = arrayListOf(first)
        while (accept(",")) xs.add(assignExpr())
        return DComma(at.line, xs).also { it.type = xs.last().type }.ok()
    }

    private fun assignExpr(): DNode = nested {
        val at = tk
        val l = binary(1)
        if (tk.kind == DTok.PUNCT && tk.text in ASSIGN_OPS) {
            val op = tk.text
            p++
            val r = assignExpr()
            checkLvalue(l)
            DAssign(at.line, op, l, r).also { it.type = l.type }.ok()
        } else l
    }

    private fun prec(t: DToken): Int {
        if (t.kind != DTok.PUNCT) return -1
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

    private fun binary(minPrec: Int): DNode {
        val first = unary()
        var steps: ArrayList<DStep>? = null
        var accType = first.type
        var height = first.height
        var lastLine = first.line
        while (true) {
            val pr = prec(tk)
            if (pr < minPrec) break
            val at = tk
            val op = tk.text
            p++
            val step: DStep
            if (pr == 5 || pr == 4) {
                val ops = arrayListOf(op)
                val rest = arrayListOf(binary(pr + 1))
                while (prec(tk).let { (it == 4 || it == 5) && it >= minPrec }) {
                    val opr = prec(tk); ops.add(tk.text); p++
                    rest.add(binary(opr + 1))
                }
                step = if (ops.size == 1) SBin(at.line, binaryType(op, accType, rest[0].type), op, rest[0])
                    else SChain(at.line, ops.toTypedArray(), rest.toTypedArray(), (listOf(accType) + rest.map { it.type }).toTypedArray())
            } else if (op == "`") {
                val r = powerOperand()
                step = SBin(at.line, DType.F64, op, r)
            } else {
                val r = binary(pr + 1)
                step = if (pr <= 3) SLogic(at.line, op, r) else SBin(at.line, binaryType(op, accType, r.type), op, r)
            }
            (steps ?: ArrayList<DStep>().also { steps = it }).add(step)
            accType = step.type
            lastLine = step.line
            // a fold is one level above its highest operand (however many steps it has)
            for (x in step.operands) if (x.height >= height) height = x.height + 1
            if (height > DynLimits.MAX_AST_HEIGHT) throw DynExpr.limit("nested deeper than ${DynLimits.MAX_AST_HEIGHT} levels", file, at.line)
        }
        val s = steps ?: return first
        return DFold(lastLine, first, s.toTypedArray()).also { it.type = accType }.ok()
    }

    /** Right operand of `` ` ``: right associative among `` ` `` only. */
    private fun powerOperand(): DNode = nested {
        val at = tk
        val b = binary(12)
        if (tk.kind == DTok.PUNCT && tk.text == "`") { p++; DBinary(at.line, "`", b, powerOperand()).also { it.type = DType.F64 }.ok() }
        else b
    }

    private fun unary(): DNode = nested {
        val at = tk
        if (tk.kind == DTok.PUNCT) {
            when (tk.text) {
                "-" -> {
                    p++
                    var e = unary()
                    // -x`y is -(x`y)
                    if (tk.kind == DTok.PUNCT && tk.text == "`") { val pa = tk; p++; e = DBinary(pa.line, "`", e, powerOperand()).also { it.type = DType.F64 }.ok() }
                    if (e is DIntLit) return@nested DIntLit(at.line, -e.v).also { it.type = DType.I64 }
                    if (e is DFloatLit) return@nested DFloatLit(at.line, -e.v).also { it.type = DType.F64 }
                    return@nested DUnary(at.line, '-', e).also {
                        it.type = if (e.type.isF64) DType.F64 else if (e.type.unsigned64) DType.U64 else DType.I64
                    }.ok()
                }
                "+" -> { p++; return@nested unary() }
                "!" -> { p++; val e = unary(); return@nested DUnary(at.line, '!', e).also { it.type = DType.I64 }.ok() }
                "~" -> { p++; val e = unary(); return@nested DUnary(at.line, '~', e).also { it.type = if (e.type.unsigned64) DType.U64 else DType.I64 }.ok() }
                "*" -> {
                    p++
                    val e = unary()
                    if (e.type == DType.U0) err("cannot dereference U0", at)
                    return@nested DUnsupported(at.line, "a pointer dereference '*'", true, listOf(e)).ok()
                }
                "&" -> {
                    p++
                    if (tk.kind == DTok.IDENT) {
                        val f = scope.symbol(tk.text) as? FuncSym
                        if (f != null && !peekP(1, "(")) {
                            p++
                            return@nested DUnsupported(at.line, "the address of the function '${f.name}'", false)
                        }
                    }
                    val e = unary()
                    if (e is DCall && e.args.isEmpty()) return@nested DUnsupported(at.line, "the address of the function '${e.name}'", false)
                    if (e is DUnsupported && e.what.startsWith("the address of the function")) return@nested e
                    checkLvalue(e)
                    return@nested DUnsupported(at.line, "the address operator '&'", false, listOf(e)).ok()
                }
                "++", "--" -> {
                    val d = if (tk.text == "++") 1 else -1
                    p++
                    val e = unary()
                    checkLvalue(e)
                    return@nested DIncDec(at.line, e, d, false).also { it.type = e.type }.ok()
                }
            }
        }
        if (tk.kind == DTok.IDENT && (tk.text == "sizeof" || tk.text == "offset")) return@nested sizeofExpr()
        postfix(primary())
    }

    private fun sizeofExpr(): DNode {
        val at = tk
        val isOffset = tk.text == "offset"
        p++
        val paren = accept("(")
        val result: DNode
        if (tk.kind == DTok.IDENT && isTypeName(tk.text) && scope.symbol(tk.text) !is GlobalSym) {
            val name = ident()
            val builtin = DType.builtins[name]
            if (accept(".")) {
                val mname = ident()
                if (builtin != null) err("not a class", at)
                result = DUnsupported(at.line, "${if (isOffset) "offset" else "sizeof"}($name.$mname)", false)
            } else {
                var stars = 0
                while (accept("*")) stars++
                result = if (stars > 0) DIntLit(at.line, 8)
                    else if (builtin != null) DIntLit(at.line, builtin.size.toLong())
                    else DUnsupported(at.line, "sizeof($name)", false)
            }
        } else {
            if (isOffset) err("offset() needs Class.member", at)
            val e = if (paren) expr() else unary()
            result = if (e.unsupported != null || e.type == DType.OTHER) DUnsupported(at.line, "sizeof of this expression", false, listOf(e))
                else DIntLit(at.line, e.type.size.toLong())
        }
        if (paren) expect(")")
        if (result is DIntLit) result.type = DType.I64
        return result
    }

    private fun primary(): DNode {
        val at = tk
        when (at.kind) {
            DTok.INT -> { p++; return DIntLit(at.line, at.ival).also { it.type = if (at.ival < 0) DType.U64 else DType.I64 } }
            DTok.CHAR -> { p++; return DIntLit(at.line, at.ival).also { it.type = DType.I64 } }
            DTok.FLOAT -> { p++; return DFloatLit(at.line, at.fval).also { it.type = DType.F64 } }
            DTok.STR -> {
                p++
                while (tk.kind == DTok.STR) p++
                return DUnsupported(at.line, "a string literal", false)
            }
            DTok.BIN -> { p++; return DUnsupported(at.line, "a binary literal", false) }
            DTok.PUNCT -> {
                if (accept("(")) {
                    val e = expr()
                    expect(")")
                    return e
                }
                err("unexpected '$tk'")
            }
            DTok.IDENT -> {
                val name = tk.text
                p++
                when (val g = scope.symbol(name)) {
                    is FuncSym -> {
                        if (isP("(")) return callArgs(name, g, at)
                        return DCall(at.line, name, g, emptyList()).also { it.type = DType.of(g.ftype.ret) }
                    }
                    is GlobalSym -> return DGlobal(at.line, g).also { it.type = DType.of(g.type) }
                    else -> {}
                }
                when (name) {
                    "TRUE" -> return DIntLit(at.line, 1).also { it.type = DType.I64 }
                    "FALSE", "NULL" -> return DIntLit(at.line, 0).also { it.type = DType.I64 }
                }
                if (scope.isKnownMacro(name)) outside("the TempleOS macro '$name' (only the numeric constants of KernelA.HH are built in)", at.line)
                err("undefined identifier '$name'", at)
            }
            DTok.EOF -> err("unexpected end of file")
        }
    }

    private fun postfix(e0: DNode): DNode {
        var e = e0
        while (true) {
            val at = tk
            if (tk.kind != DTok.PUNCT) return e
            when (tk.text) {
                "[" -> {
                    p++
                    val idx = expr()
                    expect("]")
                    if (e.type != DType.OTHER && e.unsupported == null) err("cannot index ${e.type.holyc}", at)
                    e = DUnsupported(at.line, "indexing '[ ]'", true, listOf(e, idx)).ok()
                }
                ".", "->" -> {
                    val arrow = tk.text == "->"
                    p++
                    val mname = ident()
                    if (e.type != DType.OTHER && e.unsupported == null) {
                        val bt = e.type
                        if (arrow) err("'->' on non-pointer ${bt.holyc}", at)
                        val size = if (bt.isF64) 8 else if (bt.isInt) bt.size else err("member '$mname' on ${bt.holyc}", at)
                        val sub = SUB_MEMBERS[mname]
                        if (sub == null || (sub >= size && !(sub == size && sub == 8))) err("no member '$mname' in ${bt.holyc}", at)
                    }
                    e = DUnsupported(at.line, "the member access '${if (arrow) "->" else "."}$mname'", true, listOf(e)).ok()
                }
                "(" -> {
                    if (p + 1 < lx.size && isTypeStart(lx[p + 1]) && lx[p + 1].text !in MODIFIERS) {
                        p++
                        if (tk.kind != DTok.IDENT) err("expected type")
                        val tname = tk.text
                        if (!isTypeName(tname)) err("unknown type '$tname'")
                        p++
                        var stars = 0
                        while (accept("*")) stars++
                        expect(")")
                        val to = DType.builtins[tname]
                        e = if (to != null && stars == 0) DCast(at.line, e, to).ok()
                            else DUnsupported(at.line, "a cast to $tname${"*".repeat(stars)}", isLvalue(e), listOf(e)).ok()
                        continue
                    }
                    val callable = (e is DGlobal && isFunctionPointer(e.sym)) || e.type == DType.OTHER
                    if (!callable) err("called object is not a function", at)
                    val args = parseArgs()
                    e = DUnsupported(at.line, "a call through a function pointer", false, listOf(e) + args).ok()
                }
                "++", "--" -> {
                    val d = if (tk.text == "++") 1 else -1
                    p++
                    checkLvalue(e)
                    e = DIncDec(at.line, e, d, true).also { it.type = e.type }.ok()
                }
                else -> return e
            }
        }
    }

    private fun isFunctionPointer(g: GlobalSym): Boolean {
        val t = g.type
        return t is FuncType || (t is PtrType && (t.target is FuncType || (t.target as? PtrType)?.target is FuncType))
    }

    private fun parseArgs(): List<DNode?> {
        expect("(")
        val args = ArrayList<DNode?>()
        if (!accept(")")) {
            while (true) {
                if (isP(",")) args.add(null)
                else if (isP(")")) args.add(null)
                else args.add(assignExpr())
                if (accept(")")) break
                expect(",")
            }
        }
        return args
    }

    private fun callArgs(name: String, f: FuncSym, at: DToken): DNode {
        val args = parseArgs()
        return DCall(at.line, name, f, args).also { it.type = DType.of(f.ftype.ret) }.ok()
    }

    private fun isLvalue(e: DNode): Boolean = when (e) {
        is DGlobal -> true
        is DUnsupported -> e.lvalue
        is DComma -> isLvalue(e.xs.last())
        is DCast -> isLvalue(e.e)
        else -> false
    }

    private fun checkLvalue(e: DNode) {
        if (!isLvalue(e)) throw CompileError("expression is not assignable", file, e.line)
    }

    companion object {
        val MODIFIERS = setOf(
            "public", "static", "extern", "import", "interrupt", "haserrcode", "argpop", "noargpop",
            "reg", "noreg", "native", "_extern", "_import", "_intern",
        )
        val ASSIGN_OPS = setOf("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=")
        /** Sub-integer members of integer unions (Types.intSubMember): element size by name. */
        private val SUB_MEMBERS = mapOf("i8" to 1, "u8" to 1, "i16" to 2, "u16" to 2, "i32" to 4, "u32" to 4, "i64" to 8, "u64" to 8)

        /** Parser.mkBinary's result type for scalar operands. */
        fun binaryType(op: String, lt: DType, rt: DType): DType = when (op) {
            "<", ">", "<=", ">=", "==", "!=" -> DType.I64
            "+", "-", "*", "/", "%" -> when {
                lt.isF64 || rt.isF64 -> DType.F64
                lt.unsigned64 || rt.unsigned64 -> DType.U64
                else -> DType.I64
            }
            "`" -> DType.F64
            "<<", ">>" -> if (lt.isF64) DType.I64 else if (lt.unsigned64) DType.U64 else DType.I64
            else -> if (lt.unsigned64 || rt.unsigned64) DType.U64 else DType.I64
        }
    }
}

