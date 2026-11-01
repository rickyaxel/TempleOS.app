import Foundation

// Port of core/dynexpr/DynChecker.kt.

/**
 * The functions an expression may call: TempleOS's pure math and conversion functions with scalar
 * parameters, called through the kernel exactly as compiled HolyC calls them. Parameter names are the
 * prelude's (shared/runtime/Prelude.HC, GrLib.HC for ASin/ACos/Sinh/Cosh), used in the compiler's
 * "missing argument" message; a native kernel's symbol table does not keep them.
 */
public enum DynFunctions {
    /** In the Kotlin table's order (the fuzz generator draws from it by index). */
    public static let ORDERED: [(String, [String])] = [
        // natives (shared/runtime/Prelude.HC "native F64 Sin(F64 d);" ...)
        ("Sin", ["d"]), ("Cos", ["d"]), ("Tan", ["d"]), ("ATan", ["d"]),
        ("Tanh", ["d"]), ("Arg", ["x", "y"]),
        ("Sqrt", ["d"]), ("Exp", ["d"]), ("Ln", ["d"]), ("Log2", ["d"]), ("Log10", ["d"]),
        ("Pow", ["base", "power"]), ("Pow10", ["d"]), ("Floor", ["d"]), ("Ceil", ["d"]),
        ("Round", ["d"]), ("Trunc", ["d"]), ("Abs", ["d"]),
        ("ToI64", ["d"]), ("ToF64", ["i"]), ("ToBool", ["i"]),
        ("Rand", []), ("RandI16", []), ("RandU16", []), ("RandI32", []),
        ("RandU32", []), ("RandI64", []), ("RandU64", []), ("tS", []),
        ("Bsf", ["bit_field_val"]), ("Bsr", ["bit_field_val"]), ("BCnt", ["d"]),
        // HolyC (Prelude.HC; ASin/ACos/Sinh/Cosh are GrLib.HC's, which replace the natives of the same name)
        ("ASin", ["s"]), ("ACos", ["c"]), ("Sinh", ["x"]), ("Cosh", ["x"]),
        ("Sqr", ["d"]), ("SqrI64", ["i"]), ("SqrU64", ["i"]), ("AbsI64", ["i"]),
        ("SignI64", ["i"]), ("Sign", ["d"]),
        ("MinI64", ["n1", "n2"]), ("MaxI64", ["n1", "n2"]), ("MinU64", ["n1", "n2"]), ("MaxU64", ["n1", "n2"]),
        ("Min", ["n1", "n2"]), ("Max", ["n1", "n2"]),
        ("ClampI64", ["num", "lo", "hi"]), ("ClampU64", ["num", "lo", "hi"]), ("Clamp", ["d", "lo", "hi"]),
        ("FloorI64", ["num", "to"]), ("CeilI64", ["num", "to"]),
    ]
    public static let PARAMS: [String: [String]] = Dictionary(uniqueKeysWithValues: ORDERED)
}

/** Which globals an expression may use (the running program's own scalar variables). */
public typealias DynGlobalPolicy = (GlobalSym) -> Bool

/**
 * Semantic check of a parsed statement: the subset, calls bound as the code generator binds them, and the
 * chunk frame (one temporary per chained comparison, in code generation order). Errors are raised in the
 * order the compiler's code generator would meet them.
 */
final class DynChecker {
    private let file: String
    private let policy: DynGlobalPolicy
    private var frame = 0

    init(_ file: String, _ policy: @escaping DynGlobalPolicy) { self.file = file; self.policy = policy }

    func check(_ s: DStmt) throws {
        frame = 0
        try walk(s.e)
        s.frameSize = (frame + 7) & ~7
        s.answerNone = s.e.type == .U0
    }

    private func outside(_ what: String, _ line: Int) throws -> Never { throw DynExpr.outside(what, file, line) }

    private func walk(_ e: DNode) throws {
        switch e {
        case is DIntLit, is DFloatLit: break
        case let g as DGlobal: try global(g)
        case let u as DUnary: try walk(u.e)
        case let b as DBinary: try walk(b.l); try walk(b.r)
        case let c as DCast: try walk(c.e)
        case let c as DComma: for x in c.xs { try walk(x) }
        case let f as DFold:
            // CodeGen visits the left-deep tree: chains allocate their temporary on the way down
            for s in f.steps.reversed() { if let c = s as? SChain { c.tmp = frame; frame += 8 } }
            try walk(f.first)
            for s in f.steps { for x in s.operands { try walk(x) } }
        case let a as DAssign:
            if a.op == "=" && DynEval.hasSideEffects(a.target) { try walk(a.value); try addr(a.target) }
            else { try addr(a.target); try walk(a.value) }
        case let i as DIncDec: try addr(i.target)
        case let c as DCall: try call(c)
        case let u as DUnsupported: try outside(u.what, u.line)
        default: throw CompileError("internal: unknown node", file, e.line)
        }
    }

    private func addr(_ e: DNode) throws {
        switch e {
        case let g as DGlobal: try global(g)
        case let c as DCast: try addr(c.e)
        case let c as DComma:
            for i in 0..<(c.xs.count - 1) { try walk(c.xs[i]) }
            try addr(c.xs.last!)
        case let u as DUnsupported: try outside(u.what, u.line)
        default: throw CompileError("expression is not addressable", file, e.line)
        }
    }

    private func global(_ e: DGlobal) throws {
        if !policy(e.sym) { try outside("the variable '\(e.sym.name)' (only the program's own scalar globals are available)", e.line) }
        if e.type == .OTHER || e.type == .U0 { try outside("the variable '\(e.sym.name)' of type \(e.sym.type.name) (not a scalar)", e.line) }
    }

    private func call(_ e: DCall) throws {
        guard let names = DynFunctions.PARAMS[e.name] else {
            try outside("the function '\(e.name)' (only pure math functions are evaluated natively)", e.line)
        }
        let ft = e.fn.ftype
        func scalar(_ t: HType) -> Bool { t is IntType || t is F64Type }
        if ft.varargs || ft.params.count != names.count || !ft.params.allSatisfy({ scalar($0.type) }) || !(scalar(ft.ret) || ft.ret is VoidType) {
            try outside("the function '\(e.name)' with this program's signature \(ft.name)", e.line)
        }
        // CodeGen.call: ToI64 of an integer and ToF64 of an F64 drop the call and the conversion
        if e.fn.isNative, e.args.count == 1, let a0 = e.args[0], (e.name == "ToF64" && a0.type.isF64) || (e.name == "ToI64" && !a0.type.isF64) {
            e.identity = true
            try walk(a0)
            e.bound = [a0]
            return
        }
        if e.args.count > ft.params.count { throw CompileError("too many arguments to \(e.name)", file, e.line) }
        var bound: [DNode] = []
        for (i, prm) in ft.params.enumerated() {
            let a: DNode? = i < e.args.count ? e.args[i] : nil
            guard let ex = try a ?? defaultArg(prm.defaultExpr, e.line) else {
                throw CompileError("missing argument '\(names[i])' to \(e.name)", file, e.line)
            }
            try walk(ex)
            bound.append(ex)
        }
        e.bound = bound
        e.paramTypes = ft.params.map { DType.of($0.type) }
    }

    /** A literal default argument (the only kind the whitelisted functions could have). */
    private func defaultArg(_ d: Expr?, _ line: Int) throws -> DNode? {
        guard let d = d else { return nil }
        if let i = d as? IntLit { let n = DIntLit(line, i.v); n.type = DType.of(i.type); return n }
        if let f = d as? FloatLit { let n = DFloatLit(line, f.v); n.type = .F64; return n }
        try outside("a default argument that is not a constant", line)
    }
}
