package io.github.templeosmobile.core.holyc

/**
 * Bytecode opcodes. Instructions are an opcode followed by fixed int operands.
 * The numbering is shared with the Swift runtime (see shared/specifications).
 */
object Op {
    const val NOP = 0
    const val PUSHI = 1      // imm
    const val PUSHK = 2      // constIndex
    const val POP = 3
    const val DUP = 4
    const val SWAP = 5
    const val LADDR = 6      // off

    const val LD1S = 7; const val LD1U = 8; const val LD2S = 9; const val LD2U = 10
    const val LD4S = 11; const val LD4U = 12; const val LD8 = 13
    const val LLD1S = 14; const val LLD1U = 15; const val LLD2S = 16; const val LLD2U = 17
    const val LLD4S = 18; const val LLD4U = 19; const val LLD8 = 20
    const val GLD1S = 21; const val GLD1U = 22; const val GLD2S = 23; const val GLD2U = 24
    const val GLD4S = 25; const val GLD4U = 26; const val GLD8 = 27

    const val ST1 = 28; const val ST2 = 29; const val ST4 = 30; const val ST8 = 31
    const val STK1 = 32; const val STK2 = 33; const val STK4 = 34; const val STK8 = 35
    const val LST8 = 36      // off  (value ->)
    const val LSTK8 = 37     // off  (value -> value)
    const val GST8 = 38      // addr (value ->)

    const val ADD = 40; const val SUB = 41; const val MUL = 42; const val DIVS = 43; const val DIVU = 44
    const val MODS = 45; const val MODU = 46; const val AND = 47; const val OR = 48; const val XOR = 49
    const val SHL = 50; const val SHRS = 51; const val SHRU = 52; const val POWI = 53
    const val NEG = 54; const val COM = 55; const val LNOT = 56; const val LXOR = 57; const val TOBOOL = 58
    const val EQ = 59; const val NE = 60; const val LTS = 61; const val LES = 62; const val GTS = 63; const val GES = 64
    const val LTU = 65; const val LEU = 66; const val GTU = 67; const val GEU = 68

    const val FADD = 70; const val FSUB = 71; const val FMUL = 72; const val FDIV = 73; const val FMOD = 74
    const val FPOW = 75; const val FNEG = 76
    const val FEQ = 77; const val FNE = 78; const val FLT = 79; const val FLE = 80; const val FGT = 81; const val FGE = 82
    const val I2F = 83; const val U2F = 84; const val F2I = 85
    const val SX1 = 86; const val SX2 = 87; const val SX4 = 88; const val ZX1 = 89; const val ZX2 = 90; const val ZX4 = 91

    const val JMP = 92       // target
    const val JZ = 93        // target
    const val JNZ = 94       // target
    const val SWITCH = 95    // tableIndex
    const val CALL = 96      // funcIndex nargs
    const val CALLP = 97     // nargs        (args..., fnptr ->)
    const val CALLN = 98     // nativeIndex nargs
    const val RET = 99       // (value ->)
    const val TRY = 100      // catchTarget
    const val UNTRY = 101
    const val THROW = 102    // (ch ->)
    const val ENDCATCH = 103
    const val MEMCPY = 104   // size (dst src ->)
    const val INC = 105      // kind delta post  (addr -> value)
    const val LINC8 = 106    // off delta post   (-> value)
    const val HALT = 107
    const val ADDI = 108     // imm
    const val MEMZERO = 109  // size (addr ->)
    const val JLTS = 111     // target  (a b ->) jump if !(a<b)  fused compare-branch (jump when false)
    const val JLES = 112
    const val JGTS = 113
    const val JGES = 114
    const val JEQ = 115
    const val JNE = 116
    const val MULI = 117     // imm
    /** n: reverses the top n stack slots (a1..an -> an..a1). Calls evaluate their arguments right to left, as
     *  TempleOS's compiler does, then put them back in parameter order (docs/native-validation, eval-order). */
    const val REV = 118      // n

    /** Operand counts per opcode. */
    val operands = IntArray(128).also {
        for (o in listOf(PUSHI, PUSHK, LADDR, LLD1S, LLD1U, LLD2S, LLD2U, LLD4S, LLD4U, LLD8,
            GLD1S, GLD1U, GLD2S, GLD2U, GLD4S, GLD4U, GLD8, LST8, LSTK8, GST8,
            JMP, JZ, JNZ, SWITCH, CALLP, TRY, MEMCPY, ADDI, MEMZERO, JLTS, JLES, JGTS, JGES, JEQ, JNE, MULI, REV)) it[o] = 1
        for (o in listOf(CALL, CALLN)) it[o] = 2
        it[INC] = 3; it[LINC8] = 3
    }

    // INC kinds
    const val K1S = 0; const val K1U = 1; const val K2S = 2; const val K2U = 3
    const val K4S = 4; const val K4U = 5; const val K8 = 6; const val KF64 = 7
}

class SwitchTable(val lo: Long, val dflt: Int, val targets: IntArray)
