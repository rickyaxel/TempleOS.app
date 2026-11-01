import Foundation

// Port of core/dynexpr/DynParser.kt.

/** What the parser may ask about names (answered from the kernel's symbol tables, and recorded for the cache). */
public protocol DynScope: AnyObject {
    /** The compiler's global symbol (function or variable) named [name], or nil. */
    func symbol(_ name: String) -> Sym?
    func isClassName(_ name: String) -> Bool
    /** True when a TempleOS header `#define`s [name] (outside the subset unless it is in DynMacros). */
    func isKnownMacro(_ name: String) -> Bool
}

/**
 * Recursive-descent parser for a sequence of HolyC expression statements, producing the typed AST: the
 * app's compiler front end (HolyC/Parser.swift) restricted to what can appear at the top level of ExePrint
 * text, with the same precedence climber, lookahead and error messages. Recursion is bounded by
 * DynLimits.MAX_PARSE_NESTING while parsing and DynLimits.MAX_AST_HEIGHT for the finished tree.
 */
public final class DynParser {
    private let lx: DynLexer
    private let scope: DynScope
    private let file: String
    private var p = 0
    private var nesting = 0

    init(_ lx: DynLexer, _ scope: DynScope, _ file: String) { self.lx = lx; self.scope = scope; self.file = file }

    private func tk() throws -> DToken { try lx.get(p) }

    /** The next chunk (TempleOS JIT order), or nil at the end of the text. */
    func parseChunk() throws -> DChunk? {
        if try tk().kind == .EOF { return nil }
        while try tk().kind != .EOF {
            if try accept(";") { continue } // empty statements (Parser.topLevel)
            return try statement()
        }
        return DEmpty.shared
    }

    // ================================================================ helpers

    private func err(_ msg: String, _ t: DToken? = nil) throws -> Never {
        let line = try t?.line ?? tk().line
        throw CompileError(msg, file, line)
    }
    private func outside(_ what: String, _ line: Int) throws -> Never { throw DynExpr.outside(what, file, line) }
    private func isP(_ s: String) throws -> Bool { let t = try tk(); return t.kind == .PUNCT && t.text == s }
    private func peekP(_ n: Int, _ s: String) throws -> Bool {
        guard p + n < lx.size else { return false }
        let t = try lx.get(p + n)
        return t.kind == .PUNCT && t.text == s
    }
    private func accept(_ s: String) throws -> Bool { if try isP(s) { p += 1; return true }; return false }
    private func expect(_ s: String) throws { if !(try accept(s)) { try err("expected '\(s)' but found '\(try tk())'") } }
    private func ident() throws -> String {
        let t = try tk()
        if t.kind != .IDENT { try err("expected identifier but found '\(t)'") }
        p += 1
        return t.text
    }

    @discardableResult
    private func ok<N: DNode>(_ n: N) throws -> N {
        if n.height > DynLimits.MAX_AST_HEIGHT { throw DynExpr.limit("nested deeper than \(DynLimits.MAX_AST_HEIGHT) levels", file, n.line) }
        return n
    }

    private func nested<T>(_ block: () throws -> T) throws -> T {
        nesting += 1
        if nesting > DynLimits.MAX_PARSE_NESTING { throw DynExpr.limit("nested deeper than \(DynLimits.MAX_PARSE_NESTING) sub-expressions", file, try tk().line) }
        defer { nesting -= 1 }
        return try block()
    }

    private func isTypeName(_ n: String) -> Bool { DType.builtins[n] != nil || scope.isClassName(n) }

    private func isTypeStart(_ t: DToken) -> Bool {
        if t.kind != .IDENT { return false }
        if t.text == "class" || t.text == "union" { return true }
        if DynParser.MODIFIERS.contains(t.text) { return true }
        return isTypeName(t.text)
    }

    // ================================================================ statements (Parser.topLevel / statement0)

    private func statement() throws -> DChunk {
        let at = try tk()
        if isTypeStart(at) { try outside("a declaration", at.line) }
        if at.kind == .PUNCT && at.text == "{" { try outside("a block { }", at.line) }
        if at.kind == .IDENT {
            switch at.text {
            case "if", "while", "do", "for", "switch", "break", "continue", "return", "goto", "try", "lock", "no_warn":
                try outside("the statement '\(at.text)'", at.line)
            case "CLI", "STI", "PUSHFD", "POPFD", "PAUSE", "CLD", "STD", "WBINVD", "INVLPG":
                if !(try peekP(1, "(")) {
                    if !(try peekP(1, "=")) { try outside("the x86 instruction '\(at.text)'", at.line) }
                }
            case "asm": try err("inline x86 assembly (asm {}) is not supported by \(Brand.appName)")
            default: break
            }
            if try peekP(1, ":") { try outside("a label", at.line) }
        }
        if at.kind == .STR { try outside("a string statement (Print)", at.line) }
        if at.kind == .CHAR && at.charLen == 0 {
            if !(try peekP(1, ";")) { try outside("a character output statement", at.line) }
        }
        if at.kind == .CHAR {
            if try peekP(1, ";") { try outside("a character output statement", at.line) }
            if try peekP(1, ",") { try outside("a character output statement", at.line) }
        }
        let e = try expr()
        try expect(";")
        return DStmt(e, at.line)
    }

    // ================================================================ expressions

    func expr() throws -> DNode {
        let at = try tk()
        let first = try assignExpr()
        if !(try isP(",")) { return first }
        var xs = [first]
        while try accept(",") { xs.append(try assignExpr()) }
        let c = DComma(at.line, xs); c.type = xs.last!.type
        return try ok(c)
    }

    private func assignExpr() throws -> DNode {
        try nested {
            let at = try tk()
            let l = try binary(1)
            let t = try tk()
            if t.kind == .PUNCT && DynParser.ASSIGN_OPS.contains(t.text) {
                let op = t.text
                p += 1
                let r = try assignExpr()
                try checkLvalue(l)
                let a = DAssign(at.line, op, l, r); a.type = l.type
                return try ok(a)
            }
            return l
        }
    }

    private func prec(_ t: DToken) -> Int {
        if t.kind != .PUNCT { return -1 }
        switch t.text {
        case "`", ">>", "<<": return 11
        case "*", "/", "%": return 10
        case "&": return 9
        case "^": return 8
        case "|": return 7
        case "+", "-": return 6
        case "<", ">", "<=", ">=": return 5
        case "==", "!=": return 4
        case "&&": return 3
        case "^^": return 2
        case "||": return 1
        default: return -1
        }
    }

    private func binary(_ minPrec: Int) throws -> DNode {
        let first = try unary()
        var steps: [DStep] = []
        var accType = first.type
        var height = first.height
        var lastLine = first.line
        while true {
            let pr = prec(try tk())
            if pr < minPrec { break }
            let at = try tk()
            let op = at.text
            p += 1
            let step: DStep
            if pr == 5 || pr == 4 {
                var ops = [op]
                var rest = [try binary(pr + 1)]
                while true {
                    let q = prec(try tk())
                    if !((q == 4 || q == 5) && q >= minPrec) { break }
                    ops.append(try tk().text); p += 1
                    rest.append(try binary(q + 1))
                }
                step = ops.count == 1 ? SBin(at.line, DynParser.binaryType(op, accType, rest[0].type), op, rest[0])
                    : SChain(at.line, ops, rest, [accType] + rest.map { $0.type })
            } else if op == "`" {
                let r = try powerOperand()
                step = SBin(at.line, .F64, op, r)
            } else {
                let r = try binary(pr + 1)
                step = pr <= 3 ? SLogic(at.line, op, r) : SBin(at.line, DynParser.binaryType(op, accType, r.type), op, r)
            }
            steps.append(step)
            accType = step.type
            lastLine = step.line
            // a fold is one level above its highest operand (however many steps it has)
            for x in step.operands where x.height >= height { height = x.height + 1 }
            if height > DynLimits.MAX_AST_HEIGHT { throw DynExpr.limit("nested deeper than \(DynLimits.MAX_AST_HEIGHT) levels", file, at.line) }
        }
        if steps.isEmpty { return first }
        let f = DFold(lastLine, first, steps); f.type = accType
        return try ok(f)
    }

    /** Right operand of `` ` ``: right associative among `` ` `` only. */
    private func powerOperand() throws -> DNode {
        try nested {
            let at = try tk()
            let b = try binary(12)
            let t = try tk()
            if t.kind == .PUNCT && t.text == "`" {
                p += 1
                let n = DBinary(at.line, "`", b, try powerOperand()); n.type = .F64
                return try ok(n)
            }
            return b
        }
    }

    private func unary() throws -> DNode {
        try nested {
            let at = try tk()
            if at.kind == .PUNCT {
                switch at.text {
                case "-":
                    p += 1
                    var e = try unary()
                    // -x`y is -(x`y)
                    let t = try tk()
                    if t.kind == .PUNCT && t.text == "`" {
                        p += 1
                        let n = DBinary(t.line, "`", e, try powerOperand()); n.type = .F64
                        e = try ok(n)
                    }
                    if let i = e as? DIntLit { let n = DIntLit(at.line, 0 &- i.v); n.type = .I64; return n }
                    if let f = e as? DFloatLit { let n = DFloatLit(at.line, -f.v); n.type = .F64; return n }
                    let u = DUnary(at.line, "-", e)
                    u.type = e.type.isF64 ? .F64 : (e.type.unsigned64 ? .U64 : .I64)
                    return try ok(u)
                case "+": p += 1; return try unary()
                case "!": p += 1; let e = try unary(); let u = DUnary(at.line, "!", e); u.type = .I64; return try ok(u)
                case "~": p += 1; let e = try unary(); let u = DUnary(at.line, "~", e); u.type = e.type.unsigned64 ? .U64 : .I64; return try ok(u)
                case "*":
                    p += 1
                    let e = try unary()
                    if e.type == .U0 { try err("cannot dereference U0", at) }
                    return try ok(DUnsupported(at.line, "a pointer dereference '*'", true, [e]))
                case "&":
                    p += 1
                    let t = try tk()
                    if t.kind == .IDENT, let f = scope.symbol(t.text) as? FuncSym, !(try peekP(1, "(")) {
                        p += 1
                        return DUnsupported(at.line, "the address of the function '\(f.name)'", false)
                    }
                    let e = try unary()
                    if let c = e as? DCall, c.args.isEmpty { return DUnsupported(at.line, "the address of the function '\(c.name)'", false) }
                    if let u = e as? DUnsupported, u.what.hasPrefix("the address of the function") { return u }
                    try checkLvalue(e)
                    return try ok(DUnsupported(at.line, "the address operator '&'", false, [e]))
                case "++", "--":
                    let d = at.text == "++" ? 1 : -1
                    p += 1
                    let e = try unary()
                    try checkLvalue(e)
                    let n = DIncDec(at.line, e, d, false); n.type = e.type
                    return try ok(n)
                default: break
                }
            }
            if at.kind == .IDENT && (at.text == "sizeof" || at.text == "offset") { return try sizeofExpr() }
            return try postfix(try primary())
        }
    }

    private func sizeofExpr() throws -> DNode {
        let at = try tk()
        let isOffset = at.text == "offset"
        p += 1
        let paren = try accept("(")
        let result: DNode
        let t = try tk()
        if t.kind == .IDENT && isTypeName(t.text) && !(scope.symbol(t.text) is GlobalSym) {
            let name = try ident()
            let builtin = DType.builtins[name]
            if try accept(".") {
                let mname = try ident()
                if builtin != nil { try err("not a class", at) }
                result = DUnsupported(at.line, "\(isOffset ? "offset" : "sizeof")(\(name).\(mname))", false)
            } else {
                var stars = 0
                while try accept("*") { stars += 1 }
                if stars > 0 { result = DIntLit(at.line, 8) }
                else if let bt = builtin { result = DIntLit(at.line, Int64(bt.size)) }
                else { result = DUnsupported(at.line, "sizeof(\(name))", false) }
            }
        } else {
            if isOffset { try err("offset() needs Class.member", at) }
            let e = paren ? try expr() : try unary()
            if e.unsupported != nil || e.type == .OTHER { result = DUnsupported(at.line, "sizeof of this expression", false, [e]) }
            else { result = DIntLit(at.line, Int64(e.type.size)) }
        }
        if paren { try expect(")") }
        if let r = result as? DIntLit { r.type = .I64 }
        return result
    }

    private func primary() throws -> DNode {
        let at = try tk()
        switch at.kind {
        case .INT: p += 1; let n = DIntLit(at.line, at.ival); n.type = at.ival < 0 ? .U64 : .I64; return n
        case .CHAR: p += 1; let n = DIntLit(at.line, at.ival); n.type = .I64; return n
        case .FLOAT: p += 1; let n = DFloatLit(at.line, at.fval); n.type = .F64; return n
        case .STR:
            p += 1
            while try tk().kind == .STR { p += 1 }
            return DUnsupported(at.line, "a string literal", false)
        case .BIN: p += 1; return DUnsupported(at.line, "a binary literal", false)
        case .PUNCT:
            if try accept("(") {
                let e = try expr()
                try expect(")")
                return e
            }
            try err("unexpected '\(at)'")
        case .IDENT:
            let name = at.text
            p += 1
            let g = scope.symbol(name)
            if let f = g as? FuncSym {
                if try isP("(") { return try callArgs(name, f, at) }
                let c = DCall(at.line, name, f, []); c.type = DType.of(f.ftype.ret)
                return c
            }
            if let v = g as? GlobalSym { let n = DGlobal(at.line, v); n.type = DType.of(v.type); return n }
            switch name {
            case "TRUE": let n = DIntLit(at.line, 1); n.type = .I64; return n
            case "FALSE", "NULL": let n = DIntLit(at.line, 0); n.type = .I64; return n
            default: break
            }
            if scope.isKnownMacro(name) { try outside("the TempleOS macro '\(name)' (only the numeric constants of KernelA.HH are built in)", at.line) }
            try err("undefined identifier '\(name)'", at)
        case .EOF: try err("unexpected end of file")
        }
    }

    private func postfix(_ e0: DNode) throws -> DNode {
        var e = e0
        while true {
            let at = try tk()
            if at.kind != .PUNCT { return e }
            switch at.text {
            case "[":
                p += 1
                let idx = try expr()
                try expect("]")
                if e.type != .OTHER && e.unsupported == nil { try err("cannot index \(e.type.holyc)", at) }
                e = try ok(DUnsupported(at.line, "indexing '[ ]'", true, [e, idx]))
            case ".", "->":
                let arrow = at.text == "->"
                p += 1
                let mname = try ident()
                if e.type != .OTHER && e.unsupported == nil {
                    let bt = e.type
                    if arrow { try err("'->' on non-pointer \(bt.holyc)", at) }
                    let size: Int
                    if bt.isF64 { size = 8 } else if bt.isInt { size = bt.size } else { try err("member '\(mname)' on \(bt.holyc)", at) }
                    let sub = DynParser.SUB_MEMBERS[mname]
                    if sub == nil || (sub! >= size && !(sub! == size && sub! == 8)) { try err("no member '\(mname)' in \(bt.holyc)", at) }
                }
                e = try ok(DUnsupported(at.line, "the member access '\(arrow ? "->" : ".")\(mname)'", true, [e]))
            case "(":
                if p + 1 < lx.size {
                    let n1 = try lx.get(p + 1)
                    if isTypeStart(n1) && !DynParser.MODIFIERS.contains(n1.text) {
                        p += 1
                        let tt = try tk()
                        if tt.kind != .IDENT { try err("expected type") }
                        let tname = tt.text
                        if !isTypeName(tname) { try err("unknown type '\(tname)'") }
                        p += 1
                        var stars = 0
                        while try accept("*") { stars += 1 }
                        try expect(")")
                        if let to = DType.builtins[tname], stars == 0 { e = try ok(DCast(at.line, e, to)) }
                        else { e = try ok(DUnsupported(at.line, "a cast to \(tname)\(String(repeating: "*", count: stars))", isLvalue(e), [e])) }
                        continue
                    }
                }
                var callable = e.type == .OTHER
                if let g = e as? DGlobal, isFunctionPointer(g.sym) { callable = true }
                if !callable { try err("called object is not a function", at) }
                let args = try parseArgs()
                e = try ok(DUnsupported(at.line, "a call through a function pointer", false, [e] + args))
            case "++", "--":
                let d = at.text == "++" ? 1 : -1
                p += 1
                try checkLvalue(e)
                let n = DIncDec(at.line, e, d, true); n.type = e.type
                e = try ok(n)
            default: return e
            }
        }
    }

    private func isFunctionPointer(_ g: GlobalSym) -> Bool {
        let t = g.type
        if t is FuncType { return true }
        if let pt = t as? PtrType { return pt.target is FuncType || (pt.target as? PtrType)?.target is FuncType }
        return false
    }

    private func parseArgs() throws -> [DNode?] {
        try expect("(")
        var args: [DNode?] = []
        if !(try accept(")")) {
            while true {
                if try isP(",") { args.append(nil) }
                else if try isP(")") { args.append(nil) }
                else { args.append(try assignExpr()) }
                if try accept(")") { break }
                try expect(",")
            }
        }
        return args
    }

    private func callArgs(_ name: String, _ f: FuncSym, _ at: DToken) throws -> DNode {
        let args = try parseArgs()
        let c = DCall(at.line, name, f, args); c.type = DType.of(f.ftype.ret)
        return try ok(c)
    }

    private func isLvalue(_ e: DNode) -> Bool {
        switch e {
        case is DGlobal: return true
        case let u as DUnsupported: return u.lvalue
        case let c as DComma: return isLvalue(c.xs.last!)
        case let c as DCast: return isLvalue(c.e)
        default: return false
        }
    }

    private func checkLvalue(_ e: DNode) throws {
        if !isLvalue(e) { throw CompileError("expression is not assignable", file, e.line) }
    }

    static let MODIFIERS: Set<String> = [
        "public", "static", "extern", "import", "interrupt", "haserrcode", "argpop", "noargpop",
        "reg", "noreg", "native", "_extern", "_import", "_intern",
    ]
    static let ASSIGN_OPS: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
    /** Sub-integer members of integer unions (Types.intSubMember): element size by name. */
    private static let SUB_MEMBERS: [String: Int] = ["i8": 1, "u8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8]

    /** Parser.mkBinary's result type for scalar operands. */
    static func binaryType(_ op: String, _ lt: DType, _ rt: DType) -> DType {
        switch op {
        case "<", ">", "<=", ">=", "==", "!=": return .I64
        case "+", "-", "*", "/", "%":
            if lt.isF64 || rt.isF64 { return .F64 }
            if lt.unsigned64 || rt.unsigned64 { return .U64 }
            return .I64
        case "`": return .F64
        case "<<", ">>": return lt.isF64 ? .I64 : (lt.unsigned64 ? .U64 : .I64)
        default: return lt.unsigned64 || rt.unsigned64 ? .U64 : .I64
        }
    }
}
