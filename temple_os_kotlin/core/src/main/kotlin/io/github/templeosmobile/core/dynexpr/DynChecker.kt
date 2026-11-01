package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.holyc.CompileError
import io.github.templeosmobile.core.holyc.F64Type
import io.github.templeosmobile.core.holyc.FloatLit
import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.IntLit
import io.github.templeosmobile.core.holyc.IntType
import io.github.templeosmobile.core.holyc.VoidType

/**
 * The functions an expression may call: TempleOS's pure math and conversion functions with scalar
 * parameters. Each is called through the kernel exactly as compiled HolyC calls it (the registered
 * native, or the prelude function itself — translated code in a native kernel), so results are the
 * interpreter's bit for bit. Parameter names are the prelude's (shared/runtime/Prelude.HC, GrLib.HC
 * for ASin/ACos/Sinh/Cosh), used in the compiler's "missing argument" message; a native kernel's symbol table
 * does not keep them. DynExprUnitTest checks them against the interpreter's symbols.
 */
object DynFunctions {
    val PARAMS: Map<String, List<String>> = linkedMapOf(
        // natives (shared/runtime/Prelude.HC "native F64 Sin(F64 d);" ...)
        "Sin" to listOf("d"), "Cos" to listOf("d"), "Tan" to listOf("d"), "ATan" to listOf("d"),
        "Tanh" to listOf("d"), "Arg" to listOf("x", "y"),
        "Sqrt" to listOf("d"), "Exp" to listOf("d"), "Ln" to listOf("d"), "Log2" to listOf("d"), "Log10" to listOf("d"),
        "Pow" to listOf("base", "power"), "Pow10" to listOf("d"), "Floor" to listOf("d"), "Ceil" to listOf("d"),
        "Round" to listOf("d"), "Trunc" to listOf("d"), "Abs" to listOf("d"),
        "ToI64" to listOf("d"), "ToF64" to listOf("i"), "ToBool" to listOf("i"),
        "Rand" to emptyList(), "RandI16" to emptyList(), "RandU16" to emptyList(), "RandI32" to emptyList(),
        "RandU32" to emptyList(), "RandI64" to emptyList(), "RandU64" to emptyList(), "tS" to emptyList(),
        "Bsf" to listOf("bit_field_val"), "Bsr" to listOf("bit_field_val"), "BCnt" to listOf("d"),
        // HolyC (Prelude.HC; ASin/ACos/Sinh/Cosh are GrLib.HC's, which replace the natives of the same name)
        "ASin" to listOf("s"), "ACos" to listOf("c"), "Sinh" to listOf("x"), "Cosh" to listOf("x"),
        "Sqr" to listOf("d"), "SqrI64" to listOf("i"), "SqrU64" to listOf("i"), "AbsI64" to listOf("i"),
        "SignI64" to listOf("i"), "Sign" to listOf("d"),
        "MinI64" to listOf("n1", "n2"), "MaxI64" to listOf("n1", "n2"), "MinU64" to listOf("n1", "n2"), "MaxU64" to listOf("n1", "n2"),
        "Min" to listOf("n1", "n2"), "Max" to listOf("n1", "n2"),
        "ClampI64" to listOf("num", "lo", "hi"), "ClampU64" to listOf("num", "lo", "hi"), "Clamp" to listOf("d", "lo", "hi"),
        "FloorI64" to listOf("num", "to"), "CeilI64" to listOf("num", "to"),
    )
}

/** Which globals an expression may use (the running program's own scalar variables). */
fun interface DynGlobalPolicy {
    fun isProgramGlobal(sym: GlobalSym): Boolean
}

/**
 * Semantic check of a parsed statement: the subset (only the program's scalar globals, whitelisted
 * functions with matching scalar signatures, builtin scalar casts), calls bound as the code generator
 * binds them (argument count, defaults, the ToF64/ToI64 elision, parameter conversions), and the
 * chunk frame (one temporary per chained comparison, in code generation order). Errors are raised in
 * the order the compiler's code generator would meet them.
 */
class DynChecker(private val file: String, private val policy: DynGlobalPolicy) {
    private var frame = 0

    fun check(s: DStmt) {
        frame = 0
        walk(s.e)
        s.frameSize = (frame + 7) and 7.inv()
        s.answerNone = s.e.type == DType.U0
    }

    private fun outside(what: String, line: Int): Nothing = throw DynExpr.outside(what, file, line)

    private fun walk(e: DNode) {
        when (e) {
            is DIntLit, is DFloatLit -> {}
            is DGlobal -> global(e)
            is DUnary -> walk(e.e)
            is DBinary -> { walk(e.l); walk(e.r) }
            is DCast -> walk(e.e)
            is DComma -> e.xs.forEach { walk(it) }
            is DFold -> {
                // CodeGen visits the left-deep tree: chains allocate their temporary on the way down
                for (i in e.steps.indices.reversed()) { val s = e.steps[i]; if (s is SChain) { s.tmp = frame; frame += 8 } }
                walk(e.first)
                for (s in e.steps) for (x in s.operands) walk(x)
            }
            is DAssign -> {
                if (e.op == "=" && DynEval.hasSideEffects(e.target)) { walk(e.value); addr(e.target) }
                else { addr(e.target); walk(e.value) }
            }
            is DIncDec -> addr(e.target)
            is DCall -> call(e)
            is DUnsupported -> outside(e.what, e.line)
        }
    }

    private fun addr(e: DNode) {
        when (e) {
            is DGlobal -> global(e)
            is DCast -> addr(e.e)
            is DComma -> { for (i in 0 until e.xs.size - 1) walk(e.xs[i]); addr(e.xs.last()) }
            is DUnsupported -> outside(e.what, e.line)
            else -> throw CompileError("expression is not addressable", file, e.line)
        }
    }

    private fun global(e: DGlobal) {
        if (!policy.isProgramGlobal(e.sym)) outside("the variable '${e.sym.name}' (only the program's own scalar globals are available)", e.line)
        if (e.type == DType.OTHER || e.type == DType.U0) outside("the variable '${e.sym.name}' of type ${e.sym.type.name} (not a scalar)", e.line)
    }

    private fun call(e: DCall) {
        val names = DynFunctions.PARAMS[e.name]
            ?: outside("the function '${e.name}' (only pure math functions are evaluated natively)", e.line)
        val ft = e.fn.ftype
        val scalar = { t: io.github.templeosmobile.core.holyc.Type -> t is IntType || t is F64Type }
        if (ft.varargs || ft.params.size != names.size || !ft.params.all { scalar(it.type) } || !(scalar(ft.ret) || ft.ret is VoidType))
            outside("the function '${e.name}' with this program's signature ${ft.name}", e.line)
        // CodeGen.call: ToI64 of an integer and ToF64 of an F64 drop the call and the conversion
        val a0 = e.args.singleOrNull()
        if (e.fn.isNative && a0 != null && (e.name == "ToF64" && a0.type.isF64 || e.name == "ToI64" && !a0.type.isF64)) {
            e.identity = true
            walk(a0)
            e.bound = arrayOf(a0)
            return
        }
        if (e.args.size > ft.params.size) throw CompileError("too many arguments to ${e.name}", file, e.line)
        val bound = ArrayList<DNode>()
        for ((i, prm) in ft.params.withIndex()) {
            val a = e.args.getOrNull(i)
            val ex = a ?: defaultArg(prm.default, e.line) ?: throw CompileError("missing argument '${names[i]}' to ${e.name}", file, e.line)
            walk(ex)
            bound.add(ex)
        }
        e.bound = bound.toTypedArray()
        e.paramTypes = ft.params.map { DType.of(it.type) }.toTypedArray()
    }

    /** A literal default argument (the only kind the whitelisted functions could have). */
    private fun defaultArg(d: io.github.templeosmobile.core.holyc.Expr?, line: Int): DNode? = when (d) {
        null -> null
        is IntLit -> DIntLit(line, d.v).also { it.type = DType.of(d.type) }
        is FloatLit -> DFloatLit(line, d.v).also { it.type = DType.F64 }
        else -> outside("a default argument that is not a constant", line)
    }

}
