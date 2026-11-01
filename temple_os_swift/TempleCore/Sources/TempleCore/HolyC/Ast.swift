import Foundation

// Port of holyc/Ast.kt. Kotlin sealed classes become class hierarchies
// matched with `as?` / `case let x as X`.

// MARK: - symbols

public class Sym {
    public let name: String
    public var type: HType
    init(_ name: String, _ type: HType) { self.name = name; self.type = type }
}

public final class LocalSym: Sym {
    public let offset: Int
    public init(_ name: String, _ type: HType, _ offset: Int) { self.offset = offset; super.init(name, type) }
}

public final class GlobalSym: Sym {
    public var addr: Int
    public init(_ name: String, _ type: HType, _ addr: Int) { self.addr = addr; super.init(name, type) }
}

public final class FuncSym: Sym {
    public var ftype: FuncType { type as! FuncType }
    public var index = -1               // index into Program.funcs
    public var nativeIndex = -1         // >= 0 for host functions
    public var defined = false
    public var entry = -1               // code address
    public var frameSize = 0
    public var argcSlot = -1            // frame offset of argc (varargs functions)
    public var argvSlot = -1
    public var paramOffsets: [Int] = []
    public var file = ""
    public var line = 0
    public var isNative: Bool { nativeIndex >= 0 }
    public init(_ name: String, _ type: FuncType) { super.init(name, type) }
}

// MARK: - expressions

public class Expr {
    /** Kotlin `lateinit var type`. */
    public var type: HType!
    public var file = ""
    public var line = 0
    /** Height of this expression tree (the parser bounds it: see MAX_EXPR_DEPTH). ARC frees a
     *  tree recursively, so an unbounded depth would overflow the stack in deinit. */
    public internal(set) var depth = 1
    func under(_ xs: Expr?...) { for x in xs { if let x = x, x.depth >= depth { depth = x.depth + 1 } } }
    func under(_ xs: [Expr?]) { for x in xs { if let x = x, x.depth >= depth { depth = x.depth + 1 } } }
}

public final class IntLit: Expr { public let v: Int64; public init(_ v: Int64) { self.v = v } }
public final class FloatLit: Expr { public let v: Double; public init(_ v: Double) { self.v = v } }
public final class StrLit: Expr { public let bytes: [UInt8]; public init(_ b: [UInt8]) { bytes = b } }
public final class BinLit: Expr { public let bytes: [UInt8]; public init(_ b: [UInt8]) { bytes = b } }
public final class VarRef: Expr { public let sym: Sym; public init(_ s: Sym) { sym = s } }
public final class FuncAddr: Expr { public let fn: FuncSym; public init(_ f: FuncSym) { fn = f } }
/** - ~ ! */
public final class Unary: Expr {
    public let op: String; public let e: Expr
    public init(_ op: String, _ e: Expr) { self.op = op; self.e = e; super.init(); under(e) }
}
public final class Binary: Expr {
    public let op: String; public let l: Expr; public let r: Expr
    public init(_ op: String, _ l: Expr, _ r: Expr) { self.op = op; self.l = l; self.r = r; super.init(); under(l, r) }
}
public final class Chain: Expr {
    public let ops: [String]; public let xs: [Expr]
    public init(_ ops: [String], _ xs: [Expr]) { self.ops = ops; self.xs = xs; super.init(); under(xs) }
}
/** && || ^^ */
public final class Logical: Expr {
    public let op: String; public let l: Expr; public let r: Expr
    public init(_ op: String, _ l: Expr, _ r: Expr) { self.op = op; self.l = l; self.r = r; super.init(); under(l, r) }
}
public final class Assign: Expr {
    public let op: String; public let target: Expr; public let value: Expr
    public init(_ op: String, _ target: Expr, _ value: Expr) { self.op = op; self.target = target; self.value = value; super.init(); under(target, value) }
}
public final class IncDec: Expr {
    public let target: Expr; public let delta: Int; public let post: Bool
    public init(_ target: Expr, _ delta: Int, _ post: Bool) { self.target = target; self.delta = delta; self.post = post; super.init(); under(target) }
}
public final class Call: Expr {
    public let fn: FuncSym?; public let callee: Expr?; public let ftype: FuncType; public let args: [Expr?]
    public init(_ fn: FuncSym?, _ callee: Expr?, _ ftype: FuncType, _ args: [Expr?]) { self.fn = fn; self.callee = callee; self.ftype = ftype; self.args = args; super.init(); under(callee); under(args) }
}
/** Kotlin `Index`. */
public final class IndexExpr: Expr {
    public let base: Expr; public let idx: Expr
    public init(_ base: Expr, _ idx: Expr) { self.base = base; self.idx = idx; super.init(); under(base, idx) }
}
public final class MemberAccess: Expr {
    public let base: Expr; public let offset: Int; public let viaPtr: Bool
    public init(_ base: Expr, _ offset: Int, _ viaPtr: Bool) { self.base = base; self.offset = offset; self.viaPtr = viaPtr; super.init(); under(base) }
}
public final class Deref: Expr { public let e: Expr; public init(_ e: Expr) { self.e = e; super.init(); under(e) } }
public final class AddrOf: Expr { public let e: Expr; public init(_ e: Expr) { self.e = e; super.init(); under(e) } }
public final class Cast: Expr { public let e: Expr; public init(_ e: Expr) { self.e = e; super.init(); under(e) } }
public final class Comma: Expr { public let xs: [Expr]; public init(_ xs: [Expr]) { self.xs = xs; super.init(); under(xs) } }
/** Hidden argc/argv access inside varargs functions. */
public final class ArgvRef: Expr { public override init() {} }

// MARK: - statements

public class Stmt {
    public var file = ""
    public var line = 0
}

public final class Block: Stmt { public let list: [Stmt]; public init(_ l: [Stmt]) { list = l } }
public final class ExprStmt: Stmt { public let e: Expr; public init(_ e: Expr) { self.e = e } }
public final class If: Stmt {
    public let c: Expr; public let t: Stmt; public let f: Stmt?
    public init(_ c: Expr, _ t: Stmt, _ f: Stmt?) { self.c = c; self.t = t; self.f = f }
}
public final class While: Stmt {
    public let c: Expr; public let body: Stmt
    public init(_ c: Expr, _ body: Stmt) { self.c = c; self.body = body }
}
public final class DoWhile: Stmt {
    public let body: Stmt; public let c: Expr
    public init(_ body: Stmt, _ c: Expr) { self.body = body; self.c = c }
}
public final class For: Stmt {
    public let initS: Stmt?; public let c: Expr?; public let step: Expr?; public let body: Stmt
    public init(_ initS: Stmt?, _ c: Expr?, _ step: Expr?, _ body: Stmt) { self.initS = initS; self.c = c; self.step = step; self.body = body }
}
public final class Switch: Stmt {
    public let e: Expr; public let body: [Stmt]; public let unchecked: Bool
    public init(_ e: Expr, _ body: [Stmt], _ unchecked: Bool) { self.e = e; self.body = body; self.unchecked = unchecked }
}
public final class CaseLabel: Stmt {
    public let lo: Int64; public let hi: Int64; public let isDefault: Bool
    public init(_ lo: Int64, _ hi: Int64, _ isDefault: Bool) { self.lo = lo; self.hi = hi; self.isDefault = isDefault }
}
public final class SubStart: Stmt { public override init() {} }
public final class SubEnd: Stmt { public override init() {} }
public final class Break: Stmt { public override init() {} }
public final class Continue: Stmt { public override init() {} }
public final class Return: Stmt { public let e: Expr?; public init(_ e: Expr?) { self.e = e } }
public final class Goto: Stmt { public let label: String; public init(_ l: String) { label = l } }
public final class Label: Stmt { public let name: String; public init(_ n: String) { name = n } }
public final class Try: Stmt {
    public let body: Stmt; public let handler: Stmt
    public init(_ body: Stmt, _ handler: Stmt) { self.body = body; self.handler = handler }
}
public final class LocalInit: Stmt {
    public let sym: LocalSym; public let initV: Init?
    public init(_ sym: LocalSym, _ initV: Init?) { self.sym = sym; self.initV = initV }
}
public final class GlobalInit: Stmt {
    public let sym: GlobalSym; public let initV: Init
    public init(_ sym: GlobalSym, _ initV: Init) { self.sym = sym; self.initV = initV }
}
/** Kotlin `object Nop`: use `NopStmt.shared`, test with `is NopStmt`. */
public final class NopStmt: Stmt { public static let shared = NopStmt() }

// MARK: - initializers

/** Initializer: either a single expression or a brace list. */
public class Init {}
public final class ExprInit: Init { public let e: Expr; public init(_ e: Expr) { self.e = e } }
public final class ListInit: Init { public let items: [Init]; public init(_ items: [Init]) { self.items = items } }
