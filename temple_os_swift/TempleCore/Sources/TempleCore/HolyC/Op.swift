import Foundation

/**
 * Bytecode opcodes (port of holyc/Op.kt). Instructions are an opcode followed
 * by fixed int operands. The numbering is shared with the Kotlin runtime.
 */
public enum Op {
    public static let NOP = 0
    public static let PUSHI = 1 // imm
    public static let PUSHK = 2 // constIndex
    public static let POP = 3
    public static let DUP = 4
    public static let SWAP = 5
    public static let LADDR = 6 // off
    public static let LD1S = 7; public static let LD1U = 8; public static let LD2S = 9; public static let LD2U = 10
    public static let LD4S = 11; public static let LD4U = 12; public static let LD8 = 13
    public static let LLD1S = 14; public static let LLD1U = 15; public static let LLD2S = 16; public static let LLD2U = 17
    public static let LLD4S = 18; public static let LLD4U = 19; public static let LLD8 = 20
    public static let GLD1S = 21; public static let GLD1U = 22; public static let GLD2S = 23; public static let GLD2U = 24
    public static let GLD4S = 25; public static let GLD4U = 26; public static let GLD8 = 27
    public static let ST1 = 28; public static let ST2 = 29; public static let ST4 = 30; public static let ST8 = 31
    public static let STK1 = 32; public static let STK2 = 33; public static let STK4 = 34; public static let STK8 = 35
    public static let LST8 = 36 // off  (value ->)
    public static let LSTK8 = 37 // off  (value -> value)
    public static let GST8 = 38 // addr (value ->)
    public static let ADD = 40; public static let SUB = 41; public static let MUL = 42; public static let DIVS = 43; public static let DIVU = 44
    public static let MODS = 45; public static let MODU = 46; public static let AND = 47; public static let OR = 48; public static let XOR = 49
    public static let SHL = 50; public static let SHRS = 51; public static let SHRU = 52; public static let POWI = 53
    public static let NEG = 54; public static let COM = 55; public static let LNOT = 56; public static let LXOR = 57; public static let TOBOOL = 58
    public static let EQ = 59; public static let NE = 60; public static let LTS = 61; public static let LES = 62; public static let GTS = 63; public static let GES = 64
    public static let LTU = 65; public static let LEU = 66; public static let GTU = 67; public static let GEU = 68
    public static let FADD = 70; public static let FSUB = 71; public static let FMUL = 72; public static let FDIV = 73; public static let FMOD = 74
    public static let FPOW = 75; public static let FNEG = 76
    public static let FEQ = 77; public static let FNE = 78; public static let FLT = 79; public static let FLE = 80; public static let FGT = 81; public static let FGE = 82
    public static let I2F = 83; public static let U2F = 84; public static let F2I = 85
    public static let SX1 = 86; public static let SX2 = 87; public static let SX4 = 88; public static let ZX1 = 89; public static let ZX2 = 90; public static let ZX4 = 91
    public static let JMP = 92 // target
    public static let JZ = 93 // target
    public static let JNZ = 94 // target
    public static let SWITCH = 95 // tableIndex
    public static let CALL = 96 // funcIndex nargs
    public static let CALLP = 97 // nargs        (args..., fnptr ->)
    public static let CALLN = 98 // nativeIndex nargs
    public static let RET = 99 // (value ->)
    public static let TRY = 100 // catchTarget
    public static let UNTRY = 101
    public static let THROW = 102 // (ch ->)
    public static let ENDCATCH = 103
    public static let MEMCPY = 104 // size (dst src ->)
    public static let INC = 105 // kind delta post  (addr -> value)
    public static let LINC8 = 106 // off delta post   (-> value)
    public static let HALT = 107
    public static let ADDI = 108 // imm
    public static let MEMZERO = 109 // size (addr ->)
    public static let JLTS = 111 // target  (a b ->) jump if !(a<b)  fused compare-branch (jump when false)
    public static let JLES = 112
    public static let JGTS = 113
    public static let JGES = 114
    public static let JEQ = 115
    public static let JNE = 116
    public static let MULI = 117 // imm
    /** n: reverses the top n stack slots (calls evaluate arguments right to left, as TempleOS does; Op.kt). */
    public static let REV = 118 // n
    // INC kinds
    public static let K1S = 0; public static let K1U = 1; public static let K2S = 2; public static let K2U = 3
    public static let K4S = 4; public static let K4U = 5; public static let K8 = 6; public static let KF64 = 7

    /** Operand counts per opcode. */
    public static let operands: [Int] = {
        var it = [Int](repeating: 0, count: 128)
        for o in [PUSHI, PUSHK, LADDR, LLD1S, LLD1U, LLD2S, LLD2U, LLD4S, LLD4U, LLD8,
                  GLD1S, GLD1U, GLD2S, GLD2U, GLD4S, GLD4U, GLD8, LST8, LSTK8, GST8,
                  JMP, JZ, JNZ, SWITCH, CALLP, TRY, MEMCPY, ADDI, MEMZERO, JLTS, JLES, JGTS, JGES, JEQ, JNE, MULI, REV] { it[o] = 1 }
        for o in [CALL, CALLN] { it[o] = 2 }
        it[INC] = 3; it[LINC8] = 3
        return it
    }()
}

public final class SwitchTable {
    public let lo: Int64
    public let dflt: Int
    public let targets: [Int]
    public init(_ lo: Int64, _ dflt: Int, _ targets: [Int]) { self.lo = lo; self.dflt = dflt; self.targets = targets }
}
