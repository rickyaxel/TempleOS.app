package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.holyc.FuncSym
import io.github.templeosmobile.core.holyc.Vm
import io.github.templeosmobile.core.holyc.VmFault
import io.github.templeosmobile.core.holyc.VmKill
import io.github.templeosmobile.core.holyc.f2i
import io.github.templeosmobile.core.holyc.templePow
import io.github.templeosmobile.core.holyc.u2f

/** What evaluation needs from its environment (a kernel, or a test double). */
interface DynHost {
    /** Raw little-endian load of [size] bytes (zero-extended). */
    fun ld(addr: Int, size: Int): Long
    fun st(addr: Int, size: Int, v: Long)
    /** Writes a chained comparison's temporary into the chunk's frame (as the compiled code does). */
    fun frameStore(off: Int, v: Long)
    /** Calls [fn] with word arguments, as compiled HolyC calls it (CALLN / CALL). */
    fun call(fn: FuncSym, args: LongArray): Long
    /** Cooperative cancellation: throws when the kernel is stopping. */
    fun poll()
}

/**
 * Evaluates a checked statement. The operations are the interpreter's (holyc/CodeGen.kt + holyc/Vm.kt),
 * word for word: wrapping 64-bit integer arithmetic, `DivZero` on integer division or remainder by zero
 * (and MIN/-1), shift counts masked to 6 bits, `>>` arithmetic unless the left operand is U64,
 * comparisons unsigned when either operand is unsigned, F64 promotion of integer operands (U64 through
 * the unsigned conversion), x86 truncation for F64 to integer, fdlibm `pow` for `` ` ``, IEEE `fmod` for
 * F64 `%`, postfix casts that reinterpret bits, assignments that store truncated and yield the converted
 * value. No code is generated: the tree is walked.
 */
class DynEval(private val host: DynHost) {
    /** Nodes evaluated in this call (bounded by [DynLimits.MAX_EVAL_OPS]). */
    var ops = 0
        private set
    /** The line of the most recently entered node (the compiler's line for a fault). */
    var line = 1

    fun run(s: DStmt): Long {
        line = s.line
        val v = value(s.e)
        return if (s.answerNone) 0L else v
    }

    private fun tick() {
        val n = ++ops
        if (n > DynLimits.MAX_EVAL_OPS) throw VmKill("native expression evaluation budget exceeded (${DynLimits.MAX_EVAL_OPS} operations)")
        if (n and (DynLimits.CANCEL_CHECK_EVERY - 1) == 0) host.poll()
    }

    fun value(e: DNode): Long {
        tick()
        line = e.line
        return when (e) {
            is DIntLit -> e.v
            is DFloatLit -> e.v.toRawBits()
            is DGlobal -> load(e.addr, e.type)
            is DCast -> {
                val v = value(e.e)
                if (e.type.isF64) v else narrow(v, e.type)
            }
            is DUnary -> {
                val v = value(e.e)
                val f = e.e.type.isF64
                when (e.op) {
                    '-' -> if (f) v xor Long.MIN_VALUE else -v
                    '~' -> (if (f) f2i(d(v)) else v).inv()
                    else -> if (f) b2i(d(v) == 0.0) else b2i(v == 0L)
                }
            }
            is DBinary -> binary(e.op, e.l.type, value(e.l), e.r)
            is DFold -> fold(e)
            is DAssign -> assign(e)
            is DIncDec -> incDec(addr(e.target), e.type, e.delta, e.post)
            is DCall -> call(e)
            is DComma -> { var v = 0L; for (x in e.xs) v = value(x); v }
            is DUnsupported -> throw IllegalStateException("unchecked statement")
        }
    }

    private fun fold(e: DFold): Long {
        var acc = value(e.first)
        var t = e.first.type
        for (s in e.steps) {
            acc = when (s) {
                is SBin -> binary(s.op, t, acc, s.r)
                is SLogic -> when (s.op) {
                    "^^" -> { val l = truth(acc, t); l xor truth(value(s.r), s.r.type) }
                    "&&" -> if (truth(acc, t) == 0L) 0L else truth(value(s.r), s.r.type)
                    else -> if (truth(acc, t) != 0L) 1L else truth(value(s.r), s.r.type)
                }
                is SChain -> chain(s, acc)
            }
            t = s.type
        }
        return acc
    }

    /** CodeGen.chain: each operand once, later ones only while the comparisons hold. */
    private fun chain(s: SChain, acc: Long): Long {
        val n = s.types.size
        var prev = if (s.anyF) toF(acc, s.types[0]) else acc
        for (i in 1 until n) {
            var v = value(s.rest[i - 1])
            if (s.anyF) v = toF(v, s.types[i])
            if (i < n - 1) host.frameStore(s.tmp, v)
            val r = if (s.anyF) fcmp(s.ops[i - 1], d(prev), d(v)) else icmp(s.ops[i - 1], prev, v, s.anyU)
            if (i == n - 1) return r
            if (r == 0L) return 0L
            prev = v
        }
        return 0L
    }

    /** CodeGen.binary for scalars: the left value is already computed. */
    private fun binary(op: String, lt: DType, lv: Long, rn: DNode): Long {
        val rt = rn.type
        val isF = (lt.isF64 || rt.isF64 || op == "`") && op !in INT_ONLY
        val a = if (isF) toF(lv, lt) else if (lt.isF64) f2i(d(lv)) else lv
        var b = value(rn)
        b = if (isF) toF(b, rt) else if (rt.isF64) f2i(d(b)) else b
        if (isF) return fop(op, d(a), d(b))
        val cmp = op in CMP
        val unsigned = if (cmp) lt.unsignedAny || rt.unsignedAny else lt.unsigned64 || rt.unsigned64
        return if (cmp) icmp(op, a, b, unsigned) else iop(op, a, b, unsigned, lt)
    }

    private fun fop(op: String, x: Double, y: Double): Long = when (op) {
        "+" -> (x + y).toRawBits()
        "-" -> (x - y).toRawBits()
        "*" -> (x * y).toRawBits()
        "/" -> (x / y).toRawBits()
        "%" -> (x % y).toRawBits()
        "`" -> templePow(x, y).toRawBits()
        else -> fcmp(op, x, y)
    }

    private fun fcmp(op: String, x: Double, y: Double): Long = b2i(when (op) {
        "==" -> x == y; "!=" -> x != y; "<" -> x < y; "<=" -> x <= y; ">" -> x > y
        else -> x >= y
    })

    private fun icmp(op: String, a: Long, b: Long, unsigned: Boolean): Long = b2i(when (op) {
        "==" -> a == b
        "!=" -> a != b
        "<" -> if (unsigned) java.lang.Long.compareUnsigned(a, b) < 0 else a < b
        "<=" -> if (unsigned) java.lang.Long.compareUnsigned(a, b) <= 0 else a <= b
        ">" -> if (unsigned) java.lang.Long.compareUnsigned(a, b) > 0 else a > b
        else -> if (unsigned) java.lang.Long.compareUnsigned(a, b) >= 0 else a >= b
    })

    /** CodeGen.intOp (non-comparison); [lt] decides `>>`. */
    private fun iop(op: String, a: Long, b: Long, unsigned: Boolean, lt: DType): Long = when (op) {
        "+" -> a + b
        "-" -> a - b
        "*" -> a * b
        "/" -> if (unsigned) { if (b == 0L) divZero(); java.lang.Long.divideUnsigned(a, b) }
               else { if (b == 0L || (b == -1L && a == Long.MIN_VALUE)) divZero(); if (b == -1L) -a else a / b }
        "%" -> if (unsigned) { if (b == 0L) divZero(); java.lang.Long.remainderUnsigned(a, b) }
               else { if (b == 0L || (b == -1L && a == Long.MIN_VALUE)) divZero(); if (b == -1L) 0L else a % b }
        "&" -> a and b
        "|" -> a or b
        "^" -> a xor b
        "<<" -> a shl b.toInt()
        ">>" -> if (lt.unsigned64) a ushr b.toInt() else a shr b.toInt()
        else -> throw IllegalStateException(op)
    }

    private fun divZero(): Nothing = throw VmFault(Vm.DIV_ZERO, "division by zero")

    private fun assign(e: DAssign): Long {
        val t = e.target.type
        val vt = e.value.type
        if (e.op == "=") {
            if (hasSideEffects(e.target)) {
                // the compiler evaluates the value before the target's address here (CodeGen.assign)
                val v = convert(value(e.value), vt, t)
                store(addr(e.target), t, v)
                return v
            }
            val a = addr(e.target)
            val v = convert(value(e.value), vt, t)
            store(a, t, v)
            return v
        }
        val a = addr(e.target)
        val old = load(a, t)
        val bop = e.op.substring(0, e.op.length - 1)
        val res: Long
        if ((t.isF64 || vt.isF64) && bop !in INT_ONLY) {
            val x = toF(old, t)
            val y = toF(value(e.value), vt)
            val r = fop(bop, d(x), d(y))
            res = if (t.isF64) r else f2i(d(r))
        } else {
            var y = value(e.value)
            if (vt.isF64) y = f2i(d(y))
            res = iop(bop, old, y, t.unsigned64 || vt.unsigned64, t)
        }
        store(a, t, res)
        return res
    }

    /** Address of an lvalue (a global, a cast of one, the last of a comma expression); like CodeGen.addr it does not move the line. */
    private fun addr(e: DNode): Int = when (e) {
        is DGlobal -> { tick(); e.addr }
        is DCast -> { tick(); addr(e.e) }
        is DComma -> {
            tick()
            for (i in 0 until e.xs.size - 1) value(e.xs[i])
            addr(e.xs.last())
        }
        else -> throw IllegalStateException("not an lvalue")
    }

    /** Vm.incAt: the increment at the target's width, F64 in F64. */
    private fun incDec(a: Int, t: DType, delta: Int, post: Boolean): Long {
        if (t.isF64) {
            val old = d(host.ld(a, 8)); val nv = old + delta
            host.st(a, 8, nv.toRawBits()); return (if (post) old else nv).toRawBits()
        }
        if (!t.isInt || t.size == 8) {
            val old = host.ld(a, 8); host.st(a, 8, old + delta); return if (post) old else old + delta
        }
        val raw = host.ld(a, t.size)
        val old = if (t.signed) signExtend(raw, t.size) else raw
        host.st(a, t.size, old + delta)
        val nv = if (t.signed) signExtend(old + delta, t.size) else (old + delta) and mask(t.size)
        return if (post) old else nv
    }

    private fun call(e: DCall): Long {
        if (e.identity) return value(e.bound[0])
        val n = e.bound.size
        val args = LongArray(n)
        // right to left, as TempleOS (and CodeGen.call) evaluate arguments
        for (i in n - 1 downTo 0) {
            val x = e.bound[i]
            args[i] = convert(value(x), x.type, e.paramTypes[i])
        }
        return host.call(e.fn, args)
    }

    // ------------------------------------------------------------ word operations

    private fun load(a: Int, t: DType): Long {
        if (!t.isInt) return host.ld(a, 8)
        val raw = host.ld(a, t.size)
        return if (t.signed && t.size < 8) signExtend(raw, t.size) else raw
    }

    /** Stores truncate to the target's width (CodeGen.storeOp: 8 bytes for F64 and U0). */
    private fun store(a: Int, t: DType, v: Long) = host.st(a, if (t.isInt) t.size else 8, v)

    companion object {
        private val INT_ONLY = setOf("&", "|", "^", "<<", ">>")
        private val CMP = setOf("<", "<=", ">", ">=", "==", "!=")

        fun d(v: Long): Double = java.lang.Double.longBitsToDouble(v)
        fun b2i(b: Boolean): Long = if (b) 1L else 0L
        fun truth(v: Long, t: DType): Long = if (t.isF64) b2i(d(v) != 0.0) else b2i(v != 0L)

        /** CodeGen.convert (arithmetic, no truncation): integer to F64 (U64 unsigned), F64 to integer (x86 truncation). */
        fun convert(v: Long, from: DType, to: DType): Long = when {
            to.isF64 && !from.isF64 -> toF(v, from)
            from.isF64 && !to.isF64 -> f2i(d(v))
            else -> v
        }

        fun toF(v: Long, t: DType): Long = if (t.isF64) v else if (t.unsigned64) u2f(v).toRawBits() else v.toDouble().toRawBits()

        /** CodeGen.narrow: SXn/ZXn to the storage width of [t]. */
        fun narrow(v: Long, t: DType): Long = if (!t.isInt || t.size == 8) v else if (t.signed) signExtend(v, t.size) else v and mask(t.size)

        fun signExtend(v: Long, size: Int): Long = when (size) { 1 -> v.toByte().toLong(); 2 -> v.toShort().toLong(); 4 -> v.toInt().toLong(); else -> v }
        fun mask(size: Int): Long = when (size) { 1 -> 0xFF; 2 -> 0xFFFF; 4 -> 0xFFFFFFFFL; else -> -1L }

        /** CodeGen.hasSideEffects (decides whether `=` evaluates its value before its target's address). */
        fun hasSideEffects(e: DNode?): Boolean = when (e) {
            null -> false
            is DIncDec, is DAssign, is DCall -> true
            is DCast -> hasSideEffects(e.e)
            is DUnary -> hasSideEffects(e.e)
            is DBinary -> hasSideEffects(e.l) || hasSideEffects(e.r)
            is DComma -> e.xs.any { hasSideEffects(it) }
            is DFold -> foldSideEffects(e, e.steps.size - 1)
            is DUnsupported -> true
            else -> false
        }

        /** The compiler's node for step [k] is Binary (looks at both sides) or Logical/Chain (never "has side effects"). */
        private fun foldSideEffects(e: DFold, k: Int): Boolean {
            if (k < 0) return hasSideEffects(e.first)
            val s = e.steps[k]
            return s is SBin && (foldSideEffects(e, k - 1) || hasSideEffects(s.r))
        }
    }
}
