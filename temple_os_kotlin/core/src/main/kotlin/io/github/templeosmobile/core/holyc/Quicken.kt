package io.github.templeosmobile.core.holyc

/**
 * Superinstructions by in-place quickening.
 *
 * After a function is compiled, frequent instruction sequences are fused by
 * overwriting only the opcode word of the first instruction with a fused
 * opcode. The fused instruction reads the operands of the whole sequence from
 * their original positions and then skips past it. Every original instruction
 * stays in place, so a jump into the middle of a sequence still executes the
 * original code, and no jump target, line-table entry or switch table moves.
 *
 * Sequences never include calls, returns, try/throw or natives: those save
 * the current pc for re-execution or unwinding, which must be an original
 * instruction boundary.
 *
 * Opcode numbers are shared with the Swift runtime.
 */
object Quick {
    // [LLD8 a][ADDI b][LDx]           x = *(local a + b)
    const val FLD8 = 128; const val FLD4S = 129; const val FLD4U = 130; const val FLD2S = 131
    const val FLD2U = 132; const val FLD1S = 133; const val FLD1U = 134
    // [ADDI b][LDx]                   x = *(top + b)
    const val ALD8 = 135; const val ALD4S = 136; const val ALD4U = 137; const val ALD2S = 138
    const val ALD2U = 139; const val ALD1S = 140; const val ALD1U = 141
    // [ADD][LDx]                      x = *(a + b)
    const val XLD8 = 142; const val XLD4S = 143; const val XLD4U = 144; const val XLD1U = 145
    const val LLD8_ADDI = 146       // [LLD8 a][ADDI b]
    const val LLD8_LLD8 = 147       // [LLD8 a][LLD8 b]
    const val LLD8_MULI = 148       // [LLD8 a][MULI s]
    const val MULI_ADD = 149        // [MULI s][ADD]
    const val LADDR_ADDI = 150      // [LADDR a][ADDI b]
    const val ADDI_ADDI = 151       // [ADDI a][ADDI b]
    const val PUSHI_AND = 152       // [PUSHI i][AND]
    const val PUSHI_SUB = 153
    const val PUSHI_SHL = 154
    const val PUSHI_SHRS = 155
    const val PUSHI_EQ = 156
    const val PUSHI_NE = 157
    const val TOBOOL_JZ = 158       // [TOBOOL][JZ t]
    const val TOBOOL_JNZ = 159      // [TOBOOL][JNZ t]
    const val LNOT_JZ = 160         // [LNOT][JZ t]   -> jump if value != 0
    const val LNOT_JNZ = 161        // [LNOT][JNZ t]  -> jump if value == 0
    const val ST8_LLD8 = 162        // [ST8][LLD8 a]
    const val LST8_LLD8 = 163       // [LST8 a][LLD8 b]
    const val FMUL_FADD = 164       // [FMUL][FADD]   (two roundings, like the originals)
    const val LLD8_LD8 = 165        // [LLD8 a][LD8]
    const val PUSHI_JLTS = 166      // [PUSHI i][JLTS t]
    const val LLD8_PUSHI = 167      // [LLD8 a][PUSHI i]
    const val LNOT_TOBOOL = 168     // [LNOT][TOBOOL]
    const val COUNT = 169

    private fun len(o: Int) = 1 + Op.operands[o]

    private fun fldFor(ld: Int) = when (ld) {
        Op.LD8 -> FLD8; Op.LD4S -> FLD4S; Op.LD4U -> FLD4U; Op.LD2S -> FLD2S
        Op.LD2U -> FLD2U; Op.LD1S -> FLD1S; Op.LD1U -> FLD1U; else -> -1
    }
    private fun aldFor(ld: Int) = when (ld) {
        Op.LD8 -> ALD8; Op.LD4S -> ALD4S; Op.LD4U -> ALD4U; Op.LD2S -> ALD2S
        Op.LD2U -> ALD2U; Op.LD1S -> ALD1S; Op.LD1U -> ALD1U; else -> -1
    }
    private fun xldFor(ld: Int) = when (ld) {
        Op.LD8 -> XLD8; Op.LD4S -> XLD4S; Op.LD4U -> XLD4U; Op.LD1U -> XLD1U; else -> -1
    }

    /**
     * Quickens the original (unquickened) instructions in [from, to). The
     * range must start at an instruction boundary and contain only code that
     * has not been quickened yet.
     */
    fun quicken(code: IntList, from: Int, to: Int) {
        // decode boundaries first, from the original opcodes
        val starts = IntArray(to - from + 1)
        val ops = IntArray(to - from + 1)
        var n = 0
        var i = from
        while (i < to) {
            val o = code[i]
            if (o < 0 || o >= 128) return // not original code: leave untouched
            starts[n] = i; ops[n] = o; n++
            i += len(o)
        }
        if (i != to) return
        for (j in 0 until n) {
            val o = ops[j]
            val o1 = if (j + 1 < n) ops[j + 1] else -1
            val o2 = if (j + 2 < n) ops[j + 2] else -1
            val f = when (o) {
                Op.LLD8 -> when (o1) {
                    Op.ADDI -> fldFor(o2).let { if (it >= 0) it else LLD8_ADDI }
                    Op.LLD8 -> LLD8_LLD8
                    Op.MULI -> LLD8_MULI
                    Op.LD8 -> LLD8_LD8
                    Op.PUSHI -> LLD8_PUSHI
                    else -> -1
                }
                Op.ADDI -> when (o1) {
                    Op.ADDI -> ADDI_ADDI
                    else -> aldFor(o1)
                }
                Op.ADD -> xldFor(o1)
                Op.MULI -> if (o1 == Op.ADD) MULI_ADD else -1
                Op.LADDR -> if (o1 == Op.ADDI) LADDR_ADDI else -1
                Op.PUSHI -> when (o1) {
                    Op.AND -> PUSHI_AND; Op.SUB -> PUSHI_SUB; Op.SHL -> PUSHI_SHL; Op.SHRS -> PUSHI_SHRS
                    Op.EQ -> PUSHI_EQ; Op.NE -> PUSHI_NE; Op.JLTS -> PUSHI_JLTS
                    else -> -1
                }
                Op.TOBOOL -> when (o1) { Op.JZ -> TOBOOL_JZ; Op.JNZ -> TOBOOL_JNZ; else -> -1 }
                Op.LNOT -> when (o1) { Op.JZ -> LNOT_JZ; Op.JNZ -> LNOT_JNZ; Op.TOBOOL -> LNOT_TOBOOL; else -> -1 }
                Op.ST8 -> if (o1 == Op.LLD8) ST8_LLD8 else -1
                Op.LST8 -> if (o1 == Op.LLD8) LST8_LLD8 else -1
                Op.FMUL -> if (o1 == Op.FADD) FMUL_FADD else -1
                else -> -1
            }
            if (f >= 0) code[starts[j]] = f
        }
    }
}
