import Foundation

/**
 * Superinstructions by in-place quickening (port of holyc/Quicken.kt).
 *
 * After a function is compiled, frequent instruction sequences are fused by
 * overwriting only the opcode word of the first instruction with a fused
 * opcode. The fused instruction reads the operands of the whole sequence from
 * their original positions and then skips past it. Every original instruction
 * stays in place, so a jump into the middle of a sequence still executes the
 * original code, and no jump target, line-table entry or switch table moves.
 *
 * Sequences never include calls, returns, try/throw or natives.
 * Opcode numbers are shared with the Kotlin runtime.
 */
public enum Quick {
    // [LLD8 a][ADDI b][LDx]           x = *(local a + b)
    public static let FLD8 = 128, FLD4S = 129, FLD4U = 130, FLD2S = 131, FLD2U = 132, FLD1S = 133, FLD1U = 134
    // [ADDI b][LDx]                   x = *(top + b)
    public static let ALD8 = 135, ALD4S = 136, ALD4U = 137, ALD2S = 138, ALD2U = 139, ALD1S = 140, ALD1U = 141
    // [ADD][LDx]                      x = *(a + b)
    public static let XLD8 = 142, XLD4S = 143, XLD4U = 144, XLD1U = 145
    public static let LLD8_ADDI = 146       // [LLD8 a][ADDI b]
    public static let LLD8_LLD8 = 147       // [LLD8 a][LLD8 b]
    public static let LLD8_MULI = 148       // [LLD8 a][MULI s]
    public static let MULI_ADD = 149        // [MULI s][ADD]
    public static let LADDR_ADDI = 150      // [LADDR a][ADDI b]
    public static let ADDI_ADDI = 151       // [ADDI a][ADDI b]
    public static let PUSHI_AND = 152       // [PUSHI i][AND]
    public static let PUSHI_SUB = 153
    public static let PUSHI_SHL = 154
    public static let PUSHI_SHRS = 155
    public static let PUSHI_EQ = 156
    public static let PUSHI_NE = 157
    public static let TOBOOL_JZ = 158       // [TOBOOL][JZ t]
    public static let TOBOOL_JNZ = 159      // [TOBOOL][JNZ t]
    public static let LNOT_JZ = 160         // [LNOT][JZ t]   -> jump if value != 0
    public static let LNOT_JNZ = 161        // [LNOT][JNZ t]  -> jump if value == 0
    public static let ST8_LLD8 = 162        // [ST8][LLD8 a]
    public static let LST8_LLD8 = 163       // [LST8 a][LLD8 b]
    public static let FMUL_FADD = 164       // [FMUL][FADD]   (two roundings, like the originals)
    public static let LLD8_LD8 = 165        // [LLD8 a][LD8]
    public static let PUSHI_JLTS = 166      // [PUSHI i][JLTS t]
    public static let LLD8_PUSHI = 167      // [LLD8 a][PUSHI i]
    public static let LNOT_TOBOOL = 168     // [LNOT][TOBOOL]
    public static let COUNT = 169

    private static func len(_ o: Int) -> Int { 1 + Op.operands[o] }

    private static func fldFor(_ ld: Int) -> Int {
        switch ld {
        case Op.LD8: return FLD8; case Op.LD4S: return FLD4S; case Op.LD4U: return FLD4U; case Op.LD2S: return FLD2S
        case Op.LD2U: return FLD2U; case Op.LD1S: return FLD1S; case Op.LD1U: return FLD1U; default: return -1
        }
    }
    private static func aldFor(_ ld: Int) -> Int {
        switch ld {
        case Op.LD8: return ALD8; case Op.LD4S: return ALD4S; case Op.LD4U: return ALD4U; case Op.LD2S: return ALD2S
        case Op.LD2U: return ALD2U; case Op.LD1S: return ALD1S; case Op.LD1U: return ALD1U; default: return -1
        }
    }
    private static func xldFor(_ ld: Int) -> Int {
        switch ld {
        case Op.LD8: return XLD8; case Op.LD4S: return XLD4S; case Op.LD4U: return XLD4U; case Op.LD1U: return XLD1U; default: return -1
        }
    }

    /**
     * Quickens the original (unquickened) instructions in [from, to). The
     * range must start at an instruction boundary and contain only code that
     * has not been quickened yet.
     */
    public static func quicken(_ code: IntList, _ from: Int, _ to: Int) {
        var starts: [Int] = []
        var ops: [Int] = []
        starts.reserveCapacity(to - from)
        ops.reserveCapacity(to - from)
        var i = from
        while i < to {
            let o = code[i]
            if o < 0 || o >= 128 { return } // not original code: leave untouched
            starts.append(i); ops.append(o)
            i += len(o)
        }
        if i != to { return }
        let n = ops.count
        for j in 0..<n {
            let o = ops[j]
            let o1 = j + 1 < n ? ops[j + 1] : -1
            let o2 = j + 2 < n ? ops[j + 2] : -1
            var f = -1
            switch o {
            case Op.LLD8:
                switch o1 {
                case Op.ADDI: let x = fldFor(o2); f = x >= 0 ? x : LLD8_ADDI
                case Op.LLD8: f = LLD8_LLD8
                case Op.MULI: f = LLD8_MULI
                case Op.LD8: f = LLD8_LD8
                case Op.PUSHI: f = LLD8_PUSHI
                default: break
                }
            case Op.ADDI: f = o1 == Op.ADDI ? ADDI_ADDI : aldFor(o1)
            case Op.ADD: f = xldFor(o1)
            case Op.MULI: f = o1 == Op.ADD ? MULI_ADD : -1
            case Op.LADDR: f = o1 == Op.ADDI ? LADDR_ADDI : -1
            case Op.PUSHI:
                switch o1 {
                case Op.AND: f = PUSHI_AND; case Op.SUB: f = PUSHI_SUB; case Op.SHL: f = PUSHI_SHL; case Op.SHRS: f = PUSHI_SHRS
                case Op.EQ: f = PUSHI_EQ; case Op.NE: f = PUSHI_NE; case Op.JLTS: f = PUSHI_JLTS
                default: break
                }
            case Op.TOBOOL:
                if o1 == Op.JZ { f = TOBOOL_JZ } else if o1 == Op.JNZ { f = TOBOOL_JNZ }
            case Op.LNOT:
                if o1 == Op.JZ { f = LNOT_JZ } else if o1 == Op.JNZ { f = LNOT_JNZ } else if o1 == Op.TOBOOL { f = LNOT_TOBOOL }
            case Op.ST8: f = o1 == Op.LLD8 ? ST8_LLD8 : -1
            case Op.LST8: f = o1 == Op.LLD8 ? LST8_LLD8 : -1
            case Op.FMUL: f = o1 == Op.FADD ? FMUL_FADD : -1
            default: break
            }
            if f >= 0 { code[starts[j]] = f }
        }
    }
}
