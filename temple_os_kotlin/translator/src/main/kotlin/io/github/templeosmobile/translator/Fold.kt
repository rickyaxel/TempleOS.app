package io.github.templeosmobile.translator

/**
 * Folds integer operations on constants with exactly the run-time semantics (64-bit wrapping,
 * shift counts masked to 6 bits, sign/zero extension), so `(1073741824 | (6 << 16)) | 14` prints as
 * one literal. Faulting operations (division) and floating point are never folded.
 */
object Fold {
    fun x(e: X): X = when (e) {
        is XOp -> {
            val a = x(e.a)
            val b = e.b?.let { x(it) }
            fold(e.op, a, b) ?: if (a === e.a && b === e.b) e else XOp(e.op, a, b)
        }
        is XLoad -> { val a = x(e.a); if (a === e.a) e else XLoad(e.w, e.signed, a) }
        is XLoadF -> { val a = x(e.a); if (a === e.a) e else XLoadF(a) }
        else -> e
    }

    private fun fold(op: Op, a: X, b: X?): X? {
        if (a !is XI) return null
        val v = a.v
        if (b == null) return when (op) {
            Op.NEG -> XI(-v)
            Op.COM -> XI(v.inv())
            Op.SX1 -> XI(v.toByte().toLong())
            Op.SX2 -> XI(v.toShort().toLong())
            Op.SX4 -> XI(v.toInt().toLong())
            Op.ZX1 -> XI(v and 0xFF)
            Op.ZX2 -> XI(v and 0xFFFF)
            Op.ZX4 -> XI(v and 0xFFFFFFFFL)
            Op.I2F -> XF(v.toDouble().toRawBits())
            else -> null
        }
        if (b !is XI) return null
        val w = b.v
        return when (op) {
            Op.ADD -> XI(v + w)
            Op.SUB -> XI(v - w)
            Op.MUL -> XI(v * w)
            Op.AND -> XI(v and w)
            Op.OR -> XI(v or w)
            Op.XOR -> XI(v xor w)
            Op.SHL -> XI(v shl w.toInt())
            Op.SHRS -> XI(v shr w.toInt())
            Op.SHRU -> XI(v ushr w.toInt())
            else -> null
        }
    }
}
