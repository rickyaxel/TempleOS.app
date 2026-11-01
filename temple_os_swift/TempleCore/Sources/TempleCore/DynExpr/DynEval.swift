import Foundation

// Port of core/dynexpr/DynEval.kt.

/** What evaluation needs from its environment (a kernel, or a test double). */
public protocol DynHost: AnyObject {
    /** Raw little-endian load of [size] bytes (zero-extended). */
    func ld(_ addr: Int, _ size: Int) -> Int64
    func st(_ addr: Int, _ size: Int, _ v: Int64)
    /** Writes a chained comparison's temporary into the chunk's frame (as the compiled code does). */
    func frameStore(_ off: Int, _ v: Int64)
    /** Calls [fn] with word arguments, as compiled HolyC calls it (CALLN / CALL). */
    func call(_ fn: FuncSym, _ args: [Int64]) throws -> Int64
    /** Cooperative cancellation: throws when the kernel is stopping. */
    func poll() throws
}

/**
 * Evaluates a checked statement with the interpreter's operations (HolyC/CodeGen.swift + HolyC/Vm.swift),
 * word for word. No code is generated: the tree is walked.
 */
public final class DynEval {
    private let host: DynHost
    /** Nodes evaluated in this call (bounded by DynLimits.MAX_EVAL_OPS). */
    public private(set) var ops = 0
    /** The line of the most recently entered node (the compiler's line for a fault). */
    public var line = 1

    public init(_ host: DynHost) { self.host = host }

    func run(_ s: DStmt) throws -> Int64 {
        line = s.line
        let v = try value(s.e)
        return s.answerNone ? 0 : v
    }

    private func tick() throws {
        ops += 1
        if ops > DynLimits.MAX_EVAL_OPS { throw VmKill("native expression evaluation budget exceeded (\(DynLimits.MAX_EVAL_OPS) operations)") }
        if ops & (DynLimits.CANCEL_CHECK_EVERY - 1) == 0 { try host.poll() }
    }

    func value(_ e: DNode) throws -> Int64 {
        try tick()
        line = e.line
        switch e {
        case let i as DIntLit: return i.v
        case let f as DFloatLit: return bits(f.v)
        case let g as DGlobal: return load(g.addr, g.type)
        case let c as DCast:
            let v = try value(c.e)
            return c.type.isF64 ? v : DynEval.narrow(v, c.type)
        case let u as DUnary:
            let v = try value(u.e)
            let f = u.e.type.isF64
            switch u.op {
            case "-": return f ? v ^ Int64.min : 0 &- v
            case "~": return ~(f ? f2i(d(v)) : v)
            default: return f ? DynEval.b2i(d(v) == 0.0) : DynEval.b2i(v == 0)
            }
        case let b as DBinary: return try binary(b.op, b.l.type, try value(b.l), b.r)
        case let f as DFold: return try fold(f)
        case let a as DAssign: return try assign(a)
        case let i as DIncDec: return incDec(try addr(i.target), i.type, i.delta, i.post)
        case let c as DCall: return try call(c)
        case let c as DComma: var v: Int64 = 0; for x in c.xs { v = try value(x) }; return v
        default: fatalError("unchecked statement")
        }
    }

    private func fold(_ e: DFold) throws -> Int64 {
        var acc = try value(e.first)
        var t = e.first.type
        for s in e.steps {
            if let b = s as? SBin {
                acc = try binary(b.op, t, acc, b.r)
            } else if let l = s as? SLogic {
                switch l.op {
                case "^^": let x = DynEval.truth(acc, t); acc = x ^ DynEval.truth(try value(l.r), l.r.type)
                case "&&": acc = DynEval.truth(acc, t) == 0 ? 0 : DynEval.truth(try value(l.r), l.r.type)
                default: acc = DynEval.truth(acc, t) != 0 ? 1 : DynEval.truth(try value(l.r), l.r.type)
                }
            } else if let c = s as? SChain {
                acc = try chain(c, acc)
            }
            t = s.type
        }
        return acc
    }

    /** CodeGen.chain: each operand once, later ones only while the comparisons hold. */
    private func chain(_ s: SChain, _ acc: Int64) throws -> Int64 {
        let n = s.types.count
        var prev = s.anyF ? DynEval.toF(acc, s.types[0]) : acc
        for i in 1..<n {
            var v = try value(s.rest[i - 1])
            if s.anyF { v = DynEval.toF(v, s.types[i]) }
            if i < n - 1 { host.frameStore(s.tmp, v) }
            let r = s.anyF ? fcmp(s.ops[i - 1], d(prev), d(v)) : icmp(s.ops[i - 1], prev, v, s.anyU)
            if i == n - 1 { return r }
            if r == 0 { return 0 }
            prev = v
        }
        return 0
    }

    /** CodeGen.binary for scalars: the left value is already computed. */
    private func binary(_ op: String, _ lt: DType, _ lv: Int64, _ rn: DNode) throws -> Int64 {
        let rt = rn.type
        let isF = (lt.isF64 || rt.isF64 || op == "`") && !DynEval.INT_ONLY.contains(op)
        let a = isF ? DynEval.toF(lv, lt) : (lt.isF64 ? f2i(d(lv)) : lv)
        var b = try value(rn)
        b = isF ? DynEval.toF(b, rt) : (rt.isF64 ? f2i(d(b)) : b)
        if isF { return fop(op, d(a), d(b)) }
        let cmp = DynEval.CMP.contains(op)
        let unsigned = cmp ? (lt.unsignedAny || rt.unsignedAny) : (lt.unsigned64 || rt.unsigned64)
        return cmp ? icmp(op, a, b, unsigned) : try iop(op, a, b, unsigned, lt)
    }

    private func fop(_ op: String, _ x: Double, _ y: Double) -> Int64 {
        switch op {
        case "+": return bits(x + y)
        case "-": return bits(x - y)
        case "*": return bits(x * y)
        case "/": return bits(x / y)
        case "%": return bits(x.truncatingRemainder(dividingBy: y))
        case "`": return bits(templePow(x, y))
        default: return fcmp(op, x, y)
        }
    }

    private func fcmp(_ op: String, _ x: Double, _ y: Double) -> Int64 {
        switch op {
        case "==": return DynEval.b2i(x == y)
        case "!=": return DynEval.b2i(x != y)
        case "<": return DynEval.b2i(x < y)
        case "<=": return DynEval.b2i(x <= y)
        case ">": return DynEval.b2i(x > y)
        default: return DynEval.b2i(x >= y)
        }
    }

    private func icmp(_ op: String, _ a: Int64, _ b: Int64, _ unsigned: Bool) -> Int64 {
        let ua = UInt64(bitPattern: a), ub = UInt64(bitPattern: b)
        switch op {
        case "==": return DynEval.b2i(a == b)
        case "!=": return DynEval.b2i(a != b)
        case "<": return DynEval.b2i(unsigned ? ua < ub : a < b)
        case "<=": return DynEval.b2i(unsigned ? ua <= ub : a <= b)
        case ">": return DynEval.b2i(unsigned ? ua > ub : a > b)
        default: return DynEval.b2i(unsigned ? ua >= ub : a >= b)
        }
    }

    /** CodeGen.intOp (non-comparison); [lt] decides `>>`. */
    private func iop(_ op: String, _ a: Int64, _ b: Int64, _ unsigned: Bool, _ lt: DType) throws -> Int64 {
        switch op {
        case "+": return a &+ b
        case "-": return a &- b
        case "*": return a &* b
        case "/":
            if unsigned { if b == 0 { throw divZero() }; return Int64(bitPattern: UInt64(bitPattern: a) / UInt64(bitPattern: b)) }
            if b == 0 || (b == -1 && a == Int64.min) { throw divZero() }
            return b == -1 ? 0 &- a : a / b
        case "%":
            if unsigned { if b == 0 { throw divZero() }; return Int64(bitPattern: UInt64(bitPattern: a) % UInt64(bitPattern: b)) }
            if b == 0 || (b == -1 && a == Int64.min) { throw divZero() }
            return b == -1 ? 0 : a % b
        case "&": return a & b
        case "|": return a | b
        case "^": return a ^ b
        case "<<": return a &<< (b & 63)
        case ">>": return lt.unsigned64 ? ushr(a, b) : a &>> (b & 63)
        default: fatalError(op)
        }
    }

    private func divZero() -> VmFault { VmFault(Vm.DIV_ZERO, "division by zero") }

    private func assign(_ e: DAssign) throws -> Int64 {
        let t = e.target.type
        let vt = e.value.type
        if e.op == "=" {
            if DynEval.hasSideEffects(e.target) {
                // the compiler evaluates the value before the target's address here (CodeGen.assign)
                let v = DynEval.convert(try value(e.value), vt, t)
                store(try addr(e.target), t, v)
                return v
            }
            let a = try addr(e.target)
            let v = DynEval.convert(try value(e.value), vt, t)
            store(a, t, v)
            return v
        }
        let a = try addr(e.target)
        let old = load(a, t)
        let bop = String(e.op.dropLast())
        let res: Int64
        if (t.isF64 || vt.isF64) && !DynEval.INT_ONLY.contains(bop) {
            let x = DynEval.toF(old, t)
            let y = DynEval.toF(try value(e.value), vt)
            let r = fop(bop, d(x), d(y))
            res = t.isF64 ? r : f2i(d(r))
        } else {
            var y = try value(e.value)
            if vt.isF64 { y = f2i(d(y)) }
            res = try iop(bop, old, y, t.unsigned64 || vt.unsigned64, t)
        }
        store(a, t, res)
        return res
    }

    /** Address of an lvalue; like CodeGen.addr it does not move the line. */
    private func addr(_ e: DNode) throws -> Int {
        switch e {
        case let g as DGlobal: try tick(); return g.addr
        case let c as DCast: try tick(); return try addr(c.e)
        case let c as DComma:
            try tick()
            for i in 0..<(c.xs.count - 1) { _ = try value(c.xs[i]) }
            return try addr(c.xs.last!)
        default: fatalError("not an lvalue")
        }
    }

    /** Vm.incAt: the increment at the target's width, F64 in F64. */
    private func incDec(_ a: Int, _ t: DType, _ delta: Int, _ post: Bool) -> Int64 {
        if t.isF64 {
            let old = d(host.ld(a, 8)), nv = old + Double(delta)
            host.st(a, 8, bits(nv)); return bits(post ? old : nv)
        }
        let dl = Int64(delta)
        if !t.isInt || t.size == 8 {
            let old = host.ld(a, 8); host.st(a, 8, old &+ dl); return post ? old : old &+ dl
        }
        let raw = host.ld(a, t.size)
        let old = t.signed ? DynEval.signExtend(raw, t.size) : raw
        host.st(a, t.size, old &+ dl)
        let nv = t.signed ? DynEval.signExtend(old &+ dl, t.size) : (old &+ dl) & DynEval.mask(t.size)
        return post ? old : nv
    }

    private func call(_ e: DCall) throws -> Int64 {
        if e.identity { return try value(e.bound[0]) }
        var args = [Int64](repeating: 0, count: e.bound.count)
        // right to left, as TempleOS (and CodeGen.call) evaluate arguments
        for i in stride(from: e.bound.count - 1, through: 0, by: -1) {
            let x = e.bound[i]
            args[i] = DynEval.convert(try value(x), x.type, e.paramTypes[i])
        }
        return try host.call(e.fn, args)
    }

    // ------------------------------------------------------------ word operations

    private func load(_ a: Int, _ t: DType) -> Int64 {
        if !t.isInt { return host.ld(a, 8) }
        let raw = host.ld(a, t.size)
        return t.signed && t.size < 8 ? DynEval.signExtend(raw, t.size) : raw
    }

    /** Stores truncate to the target's width (CodeGen.storeOp: 8 bytes for F64 and U0). */
    private func store(_ a: Int, _ t: DType, _ v: Int64) { host.st(a, t.isInt ? t.size : 8, v) }

    static let INT_ONLY: Set<String> = ["&", "|", "^", "<<", ">>"]
    static let CMP: Set<String> = ["<", "<=", ">", ">=", "==", "!="]

    static func b2i(_ b: Bool) -> Int64 { b ? 1 : 0 }
    static func truth(_ v: Int64, _ t: DType) -> Int64 { t.isF64 ? b2i(d(v) != 0.0) : b2i(v != 0) }

    /** CodeGen.convert (arithmetic, no truncation). */
    static func convert(_ v: Int64, _ from: DType, _ to: DType) -> Int64 {
        if to.isF64 && !from.isF64 { return toF(v, from) }
        if from.isF64 && !to.isF64 { return f2i(d(v)) }
        return v
    }

    static func toF(_ v: Int64, _ t: DType) -> Int64 { t.isF64 ? v : (t.unsigned64 ? bits(u2f(v)) : bits(Double(v))) }

    /** CodeGen.narrow: SXn/ZXn to the storage width of [t]. */
    static func narrow(_ v: Int64, _ t: DType) -> Int64 { (!t.isInt || t.size == 8) ? v : (t.signed ? signExtend(v, t.size) : v & mask(t.size)) }

    static func signExtend(_ v: Int64, _ size: Int) -> Int64 {
        switch size {
        case 1: return Int64(Int8(truncatingIfNeeded: v))
        case 2: return Int64(Int16(truncatingIfNeeded: v))
        case 4: return Int64(Int32(truncatingIfNeeded: v))
        default: return v
        }
    }
    static func mask(_ size: Int) -> Int64 {
        switch size { case 1: return 0xFF; case 2: return 0xFFFF; case 4: return 0xFFFF_FFFF; default: return -1 }
    }

    /** CodeGen.hasSideEffects (decides whether `=` evaluates its value before its target's address). */
    static func hasSideEffects(_ e: DNode?) -> Bool {
        guard let e = e else { return false }
        switch e {
        case is DIncDec, is DAssign, is DCall: return true
        case let c as DCast: return hasSideEffects(c.e)
        case let u as DUnary: return hasSideEffects(u.e)
        case let b as DBinary: return hasSideEffects(b.l) || hasSideEffects(b.r)
        case let c as DComma: return c.xs.contains { hasSideEffects($0) }
        case let f as DFold: return foldSideEffects(f, f.steps.count - 1)
        case is DUnsupported: return true
        default: return false
        }
    }

    /** The compiler's node for step [k] is Binary (looks at both sides) or Logical/Chain (never "has side effects"). */
    private static func foldSideEffects(_ e: DFold, _ k: Int) -> Bool {
        if k < 0 { return hasSideEffects(e.first) }
        guard let s = e.steps[k] as? SBin else { return false }
        return foldSideEffects(e, k - 1) || hasSideEffects(s.r)
    }
}
