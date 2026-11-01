import Foundation

// Port of core/dynexpr/DynAst.kt: the typed AST of the native dynamic expression engine (see DynExpr).
//
// Every value is a 64-bit word, as on the interpreter's operand stack: integers sign/zero-extended
// from their storage type, F64 values as raw IEEE bits. The types and their rules are HolyC's as the
// app's compiler implements them (HolyC/Parser.swift mkBinary, HolyC/CodeGen.swift).

public enum DType: Equatable {
    case U0, I8, U8, I16, U16, I32, U32, I64, U64, BOOL, F64
    /** The type of a construct outside the subset (never evaluated: the statement is rejected). */
    case OTHER

    public var size: Int {
        switch self {
        case .U0: return 0
        case .I8, .U8, .BOOL: return 1
        case .I16, .U16: return 2
        case .I32, .U32: return 4
        case .I64, .U64, .F64, .OTHER: return 8
        }
    }
    public var signed: Bool {
        switch self {
        case .U0, .U8, .U16, .U32, .U64, .BOOL: return false
        default: return true
        }
    }
    public var isInt: Bool {
        switch self {
        case .U0, .F64, .OTHER: return false
        default: return true
        }
    }
    public var holyc: String {
        switch self {
        case .U0: return "U0"; case .I8: return "I8"; case .U8: return "U8"; case .I16: return "I16"; case .U16: return "U16"
        case .I32: return "I32"; case .U32: return "U32"; case .I64: return "I64"; case .U64: return "U64"; case .BOOL: return "Bool"
        case .F64: return "F64"; case .OTHER: return "?"
        }
    }
    public var isF64: Bool { self == .F64 }
    /** Types.isUnsigned64: U64 (pointers are outside the subset). */
    public var unsigned64: Bool { self == .U64 }
    /** Types.isUnsignedAny: any unsigned integer width (comparisons are unsigned if either operand is). */
    public var unsignedAny: Bool { isInt && !signed }

    /** Types.builtins: the names a postfix cast or sizeof accepts. */
    public static let builtins: [String: DType] = [
        "U0": .U0, "I0": .U0, "I8": .I8, "U8": .U8, "I16": .I16, "U16": .U16,
        "I32": .I32, "U32": .U32, "I64": .I64, "U64": .U64, "F64": .F64, "Bool": .BOOL,
        "I8i": .I8, "U8i": .U8, "I16i": .I16, "U16i": .U16, "I32i": .I32, "U32i": .U32,
        "I64i": .I64, "U64i": .U64, "F64i": .F64, "U0i": .U0,
    ]

    /** The engine's view of a compiler type: scalars map, everything else is OTHER. */
    public static func of(_ t: HType) -> DType {
        if t is F64Type { return .F64 }
        if t is VoidType { return .U0 }
        if let i = t as? IntType {
            if i.name == "Bool" { return .BOOL }
            switch i.size {
            case 1: return i.signed ? .I8 : .U8
            case 2: return i.signed ? .I16 : .U16
            case 4: return i.signed ? .I32 : .U32
            default: return i.signed ? .I64 : .U64
            }
        }
        return .OTHER
    }
}

/** A node of the typed AST. [line] is the source line the compiler would report for it. */
public class DNode {
    public let line: Int
    public var type: DType = .OTHER
    /** Tree height (bounded by DynLimits.MAX_AST_HEIGHT). */
    public var height = 1
    /** The first construct outside the subset in this subtree, or nil (set by the parser). */
    public var unsupported: DUnsupported?

    init(_ line: Int) { self.line = line }

    func adopt(_ x: DNode?) {
        guard let x = x else { return }
        if x.height >= height { height = x.height + 1 }
        if unsupported == nil { unsupported = x.unsupported }
    }
}

/** Integer constant (INT and CHAR tokens, folded negations, sizeof). */
public final class DIntLit: DNode { public let v: Int64; init(_ line: Int, _ v: Int64) { self.v = v; super.init(line) } }

/** F64 constant. */
public final class DFloatLit: DNode { public let v: Double; init(_ line: Int, _ v: Double) { self.v = v; super.init(line) } }

/** A scalar global variable of the running program (resolved per kernel: address and width). */
public final class DGlobal: DNode {
    public let sym: GlobalSym
    public let addr: Int
    init(_ line: Int, _ sym: GlobalSym) { self.sym = sym; addr = sym.addr; super.init(line) }
}

/** `-` `!` `~` */
public final class DUnary: DNode {
    public let op: Character; public let e: DNode
    init(_ line: Int, _ op: Character, _ e: DNode) { self.op = op; self.e = e; super.init(line); adopt(e) }
}

/** A binary operator (also `` ` ``, which is right associative and parsed outside folds). */
public final class DBinary: DNode {
    public let op: String; public let l: DNode; public let r: DNode
    init(_ line: Int, _ op: String, _ l: DNode, _ r: DNode) { self.op = op; self.l = l; self.r = r; super.init(line); adopt(l); adopt(r) }
}

/**
 * One loop of the compiler's precedence climber (Parser.binary): a left-associative sequence
 * `first op1 r1 op2 r2 ...`, evaluated as a fold (same order and values as the compiler's left-deep
 * tree, bounded tree height and host recursion).
 */
public final class DFold: DNode {
    public let first: DNode; public let steps: [DStep]
    init(_ line: Int, _ first: DNode, _ steps: [DStep]) {
        self.first = first; self.steps = steps; super.init(line)
        adopt(first)
        for s in steps { for x in s.operands { adopt(x) } }
    }
}

/** A step of a DFold; [type] is the type of the accumulated value after the step. */
public class DStep {
    public let line: Int
    public let type: DType
    init(_ line: Int, _ type: DType) { self.line = line; self.type = type }
    var operands: [DNode] { [] }
}

/** Binary(op, acc, r) */
public final class SBin: DStep {
    public let op: String; public let r: DNode
    init(_ line: Int, _ type: DType, _ op: String, _ r: DNode) { self.op = op; self.r = r; super.init(line, type) }
    override var operands: [DNode] { [r] }
}

/** Logical(op, acc, r): `&&` `||` `^^` */
public final class SLogic: DStep {
    public let op: String; public let r: DNode
    init(_ line: Int, _ op: String, _ r: DNode) { self.op = op; self.r = r; super.init(line, .I64) }
    override var operands: [DNode] { [r] }
}

/** Chain(ops, [acc] + rest): chained comparisons; [types] are the operand types including the accumulator's. */
public final class SChain: DStep {
    public let ops: [String]; public let rest: [DNode]; public let types: [DType]
    public let anyF: Bool; public let anyU: Bool
    /** Frame offset of the chain's temporary (CodeGen.allocTemp), assigned by the checker. */
    public var tmp = 0
    init(_ line: Int, _ ops: [String], _ rest: [DNode], _ types: [DType]) {
        self.ops = ops; self.rest = rest; self.types = types
        anyF = types.contains { $0.isF64 }; anyU = types.contains { $0.unsignedAny }
        super.init(line, .I64)
    }
    override var operands: [DNode] { rest }
}

/** `=` and compound assignments. */
public final class DAssign: DNode {
    public let op: String; public let target: DNode; public let value: DNode
    init(_ line: Int, _ op: String, _ target: DNode, _ value: DNode) { self.op = op; self.target = target; self.value = value; super.init(line); adopt(target); adopt(value) }
}

/** `++`/`--`, prefix or postfix. */
public final class DIncDec: DNode {
    public let target: DNode; public let delta: Int; public let post: Bool
    init(_ line: Int, _ target: DNode, _ delta: Int, _ post: Bool) { self.target = target; self.delta = delta; self.post = post; super.init(line); adopt(target) }
}

/** A call of a whitelisted function; [args] may hold nils (empty argument slots). */
public final class DCall: DNode {
    public let name: String; public let fn: FuncSym; public let args: [DNode?]
    /** Bound by the checker: one expression per parameter (argument or default), with parameter types. */
    public var bound: [DNode] = []
    public var paramTypes: [DType] = []
    /** ToF64 of an F64 / ToI64 of an integer: the compiler drops the call (CodeGen.call). */
    public var identity = false
    init(_ line: Int, _ name: String, _ fn: FuncSym, _ args: [DNode?]) { self.name = name; self.fn = fn; self.args = args; super.init(line); for a in args { adopt(a) } }
}

/** Postfix type cast `e(T)`: reinterprets bits to and from F64, narrows integers. */
public final class DCast: DNode {
    public let e: DNode
    init(_ line: Int, _ e: DNode, _ to: DType) { self.e = e; super.init(line); adopt(e); type = to }
}

/** `a, b, c` (value of the last). */
public final class DComma: DNode {
    public let xs: [DNode]
    init(_ line: Int, _ xs: [DNode]) { self.xs = xs; super.init(line); for x in xs { adopt(x) } }
}

/**
 * A construct the compiler accepts but the native engine does not evaluate. The statement containing it
 * is rejected with a compile error naming [what]; [lvalue] mirrors the compiler's isLvalue.
 */
public final class DUnsupported: DNode {
    public let what: String; public let lvalue: Bool
    init(_ line: Int, _ what: String, _ lvalue: Bool, _ children: [DNode?] = []) {
        self.what = what; self.lvalue = lvalue; super.init(line)
        for c in children { adopt(c) }
        unsupported = self
    }
}

/** One executable chunk of the text (TempleOS JIT order). */
public class DChunk {}
/** An expression statement. */
public final class DStmt: DChunk {
    public let e: DNode; public let line: Int
    public var answerNone = false
    /** Size of the chunk function's frame (one 8-byte temporary per chained comparison). */
    public var frameSize = 0
    init(_ e: DNode, _ line: Int) { self.e = e; self.line = line }
}
/** Only empty statements up to the end of the text: a chunk that returns 0. */
public final class DEmpty: DChunk { public static let shared = DEmpty() }
/** The text fails to compile at this chunk. */
public final class DError: DChunk {
    public let error: CompileError; public let outsideSubset: Bool
    init(_ error: CompileError, _ outsideSubset: Bool) { self.error = error; self.outsideSubset = outsideSubset }
}
