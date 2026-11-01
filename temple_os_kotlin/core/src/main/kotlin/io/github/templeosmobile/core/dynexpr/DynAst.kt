package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.holyc.FuncSym
import io.github.templeosmobile.core.holyc.GlobalSym

/**
 * Typed AST of the native dynamic expression engine (see [DynExpr]).
 *
 * Every value is a 64-bit word, as on the interpreter's operand stack: integers sign/zero-extended
 * from their storage type, F64 values as raw IEEE bits. The types and their rules are HolyC's as the
 * app's compiler implements them (holyc/Parser.kt mkBinary, holyc/CodeGen.kt).
 */
enum class DType(val size: Int, val signed: Boolean, val isInt: Boolean, val holyc: String) {
    U0(0, false, false, "U0"),
    I8(1, true, true, "I8"), U8(1, false, true, "U8"),
    I16(2, true, true, "I16"), U16(2, false, true, "U16"),
    I32(4, true, true, "I32"), U32(4, false, true, "U32"),
    I64(8, true, true, "I64"), U64(8, false, true, "U64"),
    BOOL(1, false, true, "Bool"),
    F64(8, true, false, "F64"),
    /** The type of a construct outside the subset (never evaluated: the statement is rejected). */
    OTHER(8, true, false, "?");

    val isF64 get() = this == F64
    /** Types.isUnsigned64: U64 (pointers are outside the subset). */
    val unsigned64 get() = this == U64
    /** Types.isUnsignedAny: any unsigned integer width (comparisons are unsigned if either operand is). */
    val unsignedAny get() = isInt && !signed

    companion object {
        /** Types.builtins: the names a postfix cast or sizeof accepts. */
        val builtins: Map<String, DType> = mapOf(
            "U0" to U0, "I0" to U0, "I8" to I8, "U8" to U8, "I16" to I16, "U16" to U16,
            "I32" to I32, "U32" to U32, "I64" to I64, "U64" to U64, "F64" to F64, "Bool" to BOOL,
            "I8i" to I8, "U8i" to U8, "I16i" to I16, "U16i" to U16, "I32i" to I32, "U32i" to U32,
            "I64i" to I64, "U64i" to U64, "F64i" to F64, "U0i" to U0,
        )

        /** The engine's view of a compiler type: scalars map, everything else is [OTHER]. */
        fun of(t: io.github.templeosmobile.core.holyc.Type): DType = when (t) {
            is io.github.templeosmobile.core.holyc.F64Type -> F64
            is io.github.templeosmobile.core.holyc.VoidType -> U0
            is io.github.templeosmobile.core.holyc.IntType -> when {
                t.name == "Bool" -> BOOL
                t.size == 1 -> if (t.signed) I8 else U8
                t.size == 2 -> if (t.signed) I16 else U16
                t.size == 4 -> if (t.signed) I32 else U32
                else -> if (t.signed) I64 else U64
            }
            else -> OTHER
        }
    }
}

/** A node of the typed AST. [line] is the source line the compiler would report for it. */
sealed class DNode(@JvmField val line: Int) {
    @JvmField var type: DType = DType.OTHER
    /** Tree height (bounded by [DynLimits.MAX_AST_HEIGHT]). */
    @JvmField var height: Int = 1
    /** The first construct outside the subset in this subtree, or null (set by the parser). */
    @JvmField var unsupported: DUnsupported? = null

    protected fun under(vararg xs: DNode?) { for (x in xs) adopt(x) }
    protected fun under(xs: List<DNode?>) { for (x in xs) adopt(x) }
    protected fun adopt(x: DNode?) {
        if (x == null) return
        if (x.height >= height) height = x.height + 1
        if (unsupported == null) unsupported = x.unsupported
    }
}

/** Integer constant (INT and CHAR tokens, folded negations, sizeof). */
class DIntLit(line: Int, @JvmField val v: Long) : DNode(line)

/** F64 constant. */
class DFloatLit(line: Int, @JvmField val v: Double) : DNode(line)

/** A scalar global variable of the running program (resolved per kernel: address and width). */
class DGlobal(line: Int, @JvmField val sym: GlobalSym) : DNode(line) {
    @JvmField val addr: Int = sym.addr
}

/** `-` `!` `~` */
class DUnary(line: Int, @JvmField val op: Char, @JvmField val e: DNode) : DNode(line) { init { under(e) } }

/** A binary operator (also `` ` ``, which is right associative and parsed outside folds). */
class DBinary(line: Int, @JvmField val op: String, @JvmField val l: DNode, @JvmField val r: DNode) : DNode(line) { init { under(l, r) } }

/**
 * One loop of the compiler's precedence climber (Parser.binary): a left-associative sequence
 * `first op1 r1 op2 r2 ...`. The compiler builds a left-deep tree from it; evaluating it as a fold
 * gives the same order and values while keeping the tree height (and the host recursion) bounded by
 * the nesting depth instead of the operand count.
 */
class DFold(line: Int, @JvmField val first: DNode, @JvmField val steps: Array<DStep>) : DNode(line) {
    init {
        adopt(first)
        for (s in steps) for (x in s.operands) adopt(x)
    }
}

/** A step of a [DFold]; [type] is the type of the accumulated value after the step. */
sealed class DStep(@JvmField val line: Int, @JvmField val type: DType) { abstract val operands: List<DNode> }

/** Binary(op, acc, r) */
class SBin(line: Int, type: DType, @JvmField val op: String, @JvmField val r: DNode) : DStep(line, type) {
    override val operands get() = listOf(r)
}

/** Logical(op, acc, r): `&&` `||` `^^` */
class SLogic(line: Int, @JvmField val op: String, @JvmField val r: DNode) : DStep(line, DType.I64) {
    override val operands get() = listOf(r)
}

/**
 * Chain(ops, [acc] + rest): chained comparisons `a<b<c` (each operand evaluated once, later ones only
 * while the comparisons hold). [types] are the operand types including the accumulator's.
 */
class SChain(line: Int, @JvmField val ops: Array<String>, @JvmField val rest: Array<DNode>, @JvmField val types: Array<DType>) : DStep(line, DType.I64) {
    override val operands get() = rest.toList()
    @JvmField val anyF: Boolean = types.any { it.isF64 }
    @JvmField val anyU: Boolean = types.any { it.unsignedAny }
    /** Frame offset of the chain's temporary (CodeGen.allocTemp), assigned by the checker. */
    @JvmField var tmp: Int = 0
}

/** `=` and compound assignments. */
class DAssign(line: Int, @JvmField val op: String, @JvmField val target: DNode, @JvmField val value: DNode) : DNode(line) { init { under(target, value) } }

/** `++`/`--`, prefix or postfix. */
class DIncDec(line: Int, @JvmField val target: DNode, @JvmField val delta: Int, @JvmField val post: Boolean) : DNode(line) { init { under(target) } }

/** A call of a whitelisted function; [args] may hold nulls (empty argument slots). */
class DCall(line: Int, @JvmField val name: String, @JvmField val fn: FuncSym, @JvmField val args: List<DNode?>) : DNode(line) {
    init { under(args) }
    /** Bound by the checker: one expression per parameter (argument or default), with parameter types. */
    @JvmField var bound: Array<DNode> = emptyArray()
    @JvmField var paramTypes: Array<DType> = emptyArray()
    /** ToF64 of an F64 / ToI64 of an integer: the compiler drops the call (CodeGen.call). */
    @JvmField var identity = false
}

/** Postfix type cast `e(T)`: reinterprets bits to and from F64, narrows integers. */
class DCast(line: Int, @JvmField val e: DNode, to: DType) : DNode(line) { init { under(e); type = to } }

/** `a, b, c` (value of the last). */
class DComma(line: Int, @JvmField val xs: List<DNode>) : DNode(line) { init { under(xs) } }

/**
 * A construct the compiler accepts but the native engine does not evaluate (strings, pointers,
 * calls of other functions, other globals...). The statement containing it is rejected with a
 * compile error naming [what]; [lvalue] mirrors the compiler's isLvalue so parsing continues alike.
 */
class DUnsupported(line: Int, @JvmField val what: String, @JvmField val lvalue: Boolean, children: List<DNode?> = emptyList()) : DNode(line) {
    init { under(children); unsupported = this }
}

/** One executable chunk of the text (TempleOS JIT order: each top-level statement runs before the next is compiled). */
sealed class DChunk
/** An expression statement: [answer] is how its value is returned (Program.ANS_*: F64, integer, or none = 0). */
class DStmt(@JvmField val e: DNode, @JvmField val line: Int) : DChunk() {
    @JvmField var answerNone = false
    /** Size of the chunk function's frame (one 8-byte temporary per chained comparison). */
    @JvmField var frameSize = 0
}
/** Only empty statements up to the end of the text: a chunk that returns 0. */
object DEmpty : DChunk()
/** The text fails to compile at this chunk (parse error, compile error or outside the subset). */
class DError(@JvmField val error: io.github.templeosmobile.core.holyc.CompileError, @JvmField val outsideSubset: Boolean) : DChunk()
