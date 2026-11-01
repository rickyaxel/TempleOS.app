import Foundation

/** Largest expression tree height accepted (far above real programs; Kotlin MAX_EXPR_DEPTH). */
public let MAX_EXPR_DEPTH = 5000

/** Statement nesting accepted (Kotlin MAX_STMT_DEPTH): deterministic, not stack-dependent. */
public let MAX_STMT_DEPTH = 1000

/**
 * Recursive-descent HolyC parser producing a typed AST (port of holyc/Parser.kt).
 * Functions are handed to the code generator as soon as their body is parsed;
 * top-level statements are returned for execution after the unit is compiled.
 *
 * Token access (`tk`, `toks[i]`) is marked `try` because the lazily lexed
 * token stream can raise CompileError while pulling tokens.
 */
public final class Parser {
    private let prog: Program
    private let toks: TokenSource
    private let allowNative: Bool

    private var p = 0
    private var tk: Token { get throws { try toks[p] } }

    // ---- function context
    private var fn: FuncSym? = nil
    private var scopes: [[String: LocalSym]] = []
    private var frameTop = 0
    private var loopDepth = 0
    private var switchDepth = 0
    private var tmpCounter = 0

    public init(_ prog: Program, _ toks: TokenSource, _ allowNative: Bool) {
        self.prog = prog
        self.toks = toks
        self.allowNative = allowNative
    }

    /** Parses a whole unit; returns the top-level statements and their frame size. */
    public func parseTopLevel() throws -> ([Stmt], Int) {
        scopes = [[:]]
        staticLocals.append([:])
        frameTop = 0
        var top: [Stmt] = []
        while try tk.kind != .EOF {
            guard let s = try topLevel() else { continue }
            top.append(s)
        }
        return (top, (frameTop + 7) & ~7)
    }

    /**
     * TempleOS JIT semantics: parses top-level items up to and including the
     * next executable statement, so it can run before the rest is compiled.
     * Returns nil at end of input.
     */
    public func parseChunk() throws -> ([Stmt], Int)? {
        if try tk.kind == .EOF { return nil }
        scopes = [[:]]
        if staticLocals.isEmpty { staticLocals.append([:]) }
        frameTop = 0
        var top: [Stmt] = []
        while try tk.kind != .EOF {
            guard let s = try topLevel() else { continue }
            top.append(s)
            if executable(s) { break }
        }
        return (top, (frameTop + 7) & ~7)
    }

    private func executable(_ s: Stmt) -> Bool {
        if stackRemaining() < STACK_RESERVE { return true }
        switch s {
        case let g as GlobalInit:
            let e = (g.initV as? ExprInit)?.e
            guard let e = e else { return true }
            return ConstFold.int(e) == nil && !(e is StrLit) && ConstFold.float(e) == nil
        case let b as Block:
            return b.list.contains { executable($0) }
        case is NopStmt:
            return false
        default:
            return true
        }
    }

    // ================================================================ helpers

    private func err(_ msg: String) throws -> Never { try err(msg, tk) }
    private func err(_ msg: String, _ t: Token) throws -> Never { throw CompileError(msg, t.file, t.line) }
    private func isP(_ s: String) throws -> Bool { try tk.kind == .PUNCT && tk.text == s }
    private func isId(_ s: String) throws -> Bool { try tk.kind == .IDENT && tk.text == s }
    private func peekP(_ n: Int, _ s: String) throws -> Bool {
        try p + n < toks.size && toks[p + n].kind == .PUNCT && toks[p + n].text == s
    }
    @discardableResult
    private func accept(_ s: String) throws -> Bool {
        if try isP(s) { p += 1; return true }
        return false
    }
    private func expect(_ s: String) throws {
        if try !accept(s) { try err("expected '\(s)' but found '\(tk.description)'") }
    }
    private func ident() throws -> String {
        if try tk.kind != .IDENT { try err("expected identifier but found '\(tk.description)'") }
        let t = try toks[p]
        p += 1
        return t.text
    }
    @discardableResult
    private func at<E: Expr>(_ e: E, _ t: Token) -> E {
        // Deep trees (e.g. generated 1+1+...+1 chains) are rejected; the error is raised at the
        // next unary()/postfix step/statement (this helper is not throwing).
        if e.depth > MAX_EXPR_DEPTH && tooDeepAt == nil { tooDeepAt = t }
        e.file = t.file; e.line = t.line; return e
    }
    private var tooDeepAt: Token?
    private func checkDepth() throws {
        if let t = tooDeepAt { throw CompileError("expression too deeply nested", t.file, t.line) }
    }
    @discardableResult
    private func at<S: Stmt>(_ s: S, _ t: Token) -> S { s.file = t.file; s.line = t.line; return s }
    /** Kotlin `.also { it.type = t }`. */
    private func typed<E: Expr>(_ e: E, _ t: HType) -> E { e.type = t; return e }

    private let modifiers: Set<String> = [
        "public", "static", "extern", "import", "interrupt", "haserrcode", "argpop", "noargpop",
        "reg", "noreg", "native", "_extern", "_import", "_intern",
    ]

    private func typeNamed(_ n: String) -> HType? { Types.builtins[n] ?? prog.classes[n] }

    private func isTypeStart() throws -> Bool { try isTypeStart(tk) }

    private func isTypeStart(_ t: Token) -> Bool {
        if t.kind != .IDENT { return false }
        if t.text == "class" || t.text == "union" { return true }
        if modifiers.contains(t.text) { return true }
        if lookupLocal(t.text) != nil { return false }
        return typeNamed(t.text) != nil
    }

    private func lookupLocal(_ n: String) -> LocalSym? {
        for i in scopes.indices.reversed() { if let l = scopes[i][n] { return l } }
        return nil
    }

    // ================================================================ top level

    private func topLevel() throws -> Stmt? {
        if try accept(";") { return nil }
        if try isTypeStart() { return try declaration(global: true) }
        return try statement()
    }

    /** Parses `Type a=1, *b, c[3];`, class definitions and function definitions. */
    private func declaration(global: Bool) throws -> Stmt? {
        try checkStack()
        let start = try tk
        var isNative = false
        var isExtern = false
        var isStatic = false
        while try tk.kind == .IDENT && modifiers.contains(tk.text) {
            switch try tk.text {
            case "native":
                if !allowNative { try err("'native' is only allowed in the system prelude") }
                isNative = true
            case "extern", "import": isExtern = true
            case "static": isStatic = true
            case "_extern", "_import", "_intern": p += 1; isExtern = true
            default: break
            }
            p += 1
        }
        // Optional value type for classes: `I64 class X {...}` / `public U32i union Y {...}`
        var valueType: IntType? = nil
        if try tk.kind == .IDENT && (Types.builtins[tk.text] as? IntType) != nil && p + 1 < toks.size &&
            (toks[p + 1].text == "class" || toks[p + 1].text == "union") {
            valueType = try Types.builtins[tk.text] as? IntType
            p += 1
        }
        if try isId("class") || isId("union") {
            let cls = try classDef(valueType)
            if try accept(";") { return nil }
            // TempleOS also accepts a class definition without the closing ';' when the
            // next declaration starts right away (Demo/Graphics/Pick3D.HC)
            let nt = try tk
            if nt.kind == .IDENT && (nt.text == "class" || nt.text == "union" || modifiers.contains(nt.text) || typeNamed(nt.text) != nil) { return nil }
            // `class X {...} x;` - declarators follow
            return try declarators(cls, global, isNative, isExtern, isStatic, start)
        }
        let base = try baseType()
        return try declarators(base, global, isNative, isExtern, isStatic, start)
    }

    private func baseType() throws -> HType {
        try checkStack()
        if try tk.kind != .IDENT { try err("expected type") }
        guard let t = try typeNamed(tk.text) else { try err("unknown type '\(tk.text)'") }
        p += 1
        return t
    }

    private func classDef(_ valueType: IntType?) throws -> ClassType {
        try checkStack()
        let isUnion = try tk.text == "union"
        p += 1
        let name = try ident()
        let existing = prog.classes[name]
        let cls = (existing != nil && !existing!.defined) ? existing! : ClassType(name, isUnion)
        prog.classes[name] = cls
        cls.valueType = valueType
        if try !isP("{") && !isP(":") { return cls } // forward declaration
        if try accept(":") {
            guard let b = try prog.classes[ident()] else { try err("unknown base class") }
            cls.base = b
            for m in b.memberList { cls.setMember(m.name, m) }
            cls.sizeValue = b.size
        }
        try expect("{")
        _ = try classBody(cls, cls.size, isUnion)
        try expect("}")
        cls.defined = true
        return cls
    }

    /** Parses members into [cls] starting at [base]; returns the end offset. */
    private func classBody(_ cls: ClassType, _ base: Int, _ isUnion: Bool) throws -> Int {
        try checkStack()
        var off = base
        var maxEnd = base
        while try !isP("}") {
            if try accept(";") { continue }
            if try (isId("union") || isId("class")) && peekP(1, "{") {
                // anonymous nested union/class: members are placed inline
                let nestedUnion = try tk.text == "union"
                p += 1
                try expect("{")
                let end = try classBody(cls, off, nestedUnion)
                try expect("}")
                try accept(";")
                if isUnion { maxEnd = max(maxEnd, end) } else { off = end; maxEnd = off }
                continue
            }
            while try tk.kind == .IDENT && modifiers.contains(tk.text) { p += 1 }
            let bt: HType = try (isId("class") || isId("union")) ? classDef(nil) : baseType()
            while true {
                let (name, t) = try declarator(bt)
                // member meta data: `format "..."`, `data ...` etc.
                var memberFormat: [UInt8]?
                while try tk.kind == .IDENT {
                    let meta = try tk.text; p += 1
                    if try !isP(",") && !isP(";") {
                        let value = try assignExpr()
                        if meta == "format" { memberFormat = (value as? StrLit)?.bytes }
                    }
                }
                let mOff = isUnion ? base : off
                if !name.isEmpty { cls.setMember(name, Member(name, t, mOff, memberFormat)) }
                if isUnion { maxEnd = max(maxEnd, base + t.size) } else { off += t.size; maxEnd = off }
                if try !accept(",") { break }
            }
            try expect(";")
        }
        cls.sizeValue = max(cls.size, maxEnd)
        return maxEnd
    }

    /** Kotlin `Regex("^R[0-9A-Z]{1,3}$").matches(s)`. */
    private static func isRegName(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        if u.count < 2 || u.count > 4 || u[0] != "R" { return false }
        for c in u.dropFirst() {
            if !((c >= "0" && c <= "9") || (c >= "A" && c <= "Z")) { return false }
        }
        return true
    }

    /** Parses pointer stars, the name, array dims and function-pointer syntax. */
    /** Skips register hints: `reg`, `reg R15`, `noreg` (meaningless without x86 codegen). */
    private func skipRegHints() throws {
        while try tk.kind == .IDENT && (tk.text == "reg" || tk.text == "noreg") {
            p += 1
            if try tk.kind == .IDENT && Parser.isRegName(tk.text) && p + 1 < toks.size && toks[p + 1].kind == .IDENT { p += 1 }
        }
    }

    private func declarator(_ base: HType) throws -> (String, HType) {
        var t = base
        try skipRegHints()
        while try accept("*") { t = PtrType(t) }
        try skipRegHints()
        if try isP("(") && peekP(1, "*") {
            // function pointer: Type (*name)(params)
            p += 2
            var extraStars = 0
            while try accept("*") { extraStars += 1 }
            let name = try tk.kind == .IDENT ? ident() : ""
            try expect(")")
            try expect("(")
            let (params, va) = try paramList()
            var ft: HType = PtrType(FuncType(t, params, va))
            for _ in 0..<extraStars { ft = PtrType(ft) }
            return (name, ft)
        }
        let name: String
        if try tk.kind == .IDENT && !isTypeStart() { name = try ident() }
        else if try tk.kind == .IDENT { name = try ident() }
        else { name = "" }
        t = try arrayDims(t)
        return (name, t)
    }

    private func arrayDims(_ t0: HType) throws -> HType {
        var dims: [Int] = []
        while try accept("[") {
            if try accept("]") { dims.append(-1); continue }
            let e = try assignExpr()
            dims.append(Int(Int32(truncatingIfNeeded: try constInt(e))))
            try expect("]")
        }
        // A negative or oversized dimension is a compile error, so every array size is a real Int: the
        // size used to trap the whole app here (Kotlin wrapped), letting an initializer write anywhere.
        var total = Int64(t0.size)
        // Validate each inner type before an outer zero dimension can mask its oversized stride.
        for d in dims.reversed() {
            if d < -1 { try err("array dimension out of range") }
            if d >= 0 { total *= Int64(d); if total > Int64(Int32.max) { try err("array too large") } }
        }
        var t = t0
        for d in dims.reversed() { t = ArrType(t, d) }
        return t
    }

    private func paramList() throws -> ([Param], Bool) {
        var params: [Param] = []
        var va = false
        if try accept(")") { return (params, false) }
        while true {
            if try accept("...") { va = true; try expect(")"); break }
            while try tk.kind == .IDENT && modifiers.contains(tk.text) { p += 1 }
            let bt = try baseType()
            let (name, t0) = try declarator(bt)
            let t: HType = (t0 as? ArrType).map { PtrType($0.elem) } ?? t0
            var def: Expr? = nil
            if try accept("=") {
                if try isId("lastclass") { p += 1; def = typed(StrLit(latin1("@lastclass")), Types.U8Ptr) } else { def = try assignExpr() }
            }
            params.append(Param(name, t, def))
            if try accept(")") { break }
            try expect(",")
        }
        return (params, va)
    }

    private func declarators(_ base: HType, _ global: Bool, _ isNative: Bool, _ isExtern: Bool, _ isStatic: Bool, _ start: Token) throws -> Stmt? {
        var out: [Stmt] = []
        while true {
            let at = try tk
            var t = base
            while try accept("*") { t = PtrType(t) }
            // function definition or prototype?
            if try tk.kind == .IDENT && peekP(1, "(") && !(p + 2 < toks.size && toks[p + 2].text == "*") {
                let name = try ident()
                try expect("(")
                let (params, va) = try paramList()
                let ft = FuncType(t, params, va)
                if try fn != nil && !isP("{") {
                    // prototype inside a function body: ignore
                    try expect(";"); return nil
                }
                try funcDef(name, ft, isNative, at)
                return out.isEmpty ? nil : self.at(Block(out), start)
            }
            let (name, dt0) = try declarator(t)
            if name.isEmpty { try err("expected a variable name") }
            var dt = dt0
            var initV: Init? = nil
            if try accept("=") { initV = try initializer() }
            // infer [] size from initializer
            if let a = dt as? ArrType, a.count < 0 {
                let n: Int
                if let li = initV as? ListInit { n = li.items.count }
                else if let ei = initV as? ExprInit { n = (ei.e as? StrLit).map { $0.bytes.count + 1 } ?? 0 }
                else { n = 0 }
                dt = ArrType(a.elem, n)
            }
            if global || isStatic {
                let g = try declareGlobal(name, dt, isExtern, at)
                if let iv = initV { out.append(self.at(GlobalInit(g, iv), at)) }
            } else {
                let l = declareLocal(name, dt, at)
                out.append(self.at(LocalInit(l, initV), at))
            }
            if try !accept(",") { break }
            if try isP(";") { break } // `I64 a,b,;` (Demo/Graphics/Life.HC)
        }
        try expect(";")
        switch out.count {
        case 0: return nil
        case 1: return out[0]
        default: return at(Block(out), start)
        }
    }

    private func initializer() throws -> Init {
        try checkStack()
        if try accept("{") {
            var items: [Init] = []
            while try !isP("}") {
                items.append(try initializer())
                if try !accept(",") { break }
            }
            try expect("}")
            return ListInit(items)
        }
        return ExprInit(try assignExpr())
    }

    private func declareGlobal(_ name: String, _ t: HType, _ isExtern: Bool, _ at: Token) throws -> GlobalSym {
        if let old = prog.globals[name] as? GlobalSym {
            if isExtern || old.type.size == t.size { return old }
        }
        if fn != nil {
            // static local: lives in global storage, visible only in this function
            let g = GlobalSym(name, t, try prog.allocGlobal(t.size))
            staticLocals[staticLocals.count - 1][name] = g
            return g
        }
        let g = GlobalSym(name, t, try prog.allocGlobal(max(t.size, 1)))
        prog.globals[name] = g
        return g
    }

    private var staticLocals: [[String: GlobalSym]] = []

    private func declareLocal(_ name: String, _ t: HType, _ at: Token) -> LocalSym {
        let size = max(t.size, 1)
        frameTop = (frameTop + 7) & ~7
        let l = LocalSym(name, t, frameTop)
        frameTop += size
        scopes[scopes.count - 1][name] = l
        return l
    }

    private func funcDef(_ name: String, _ ft: FuncType, _ isNative: Bool, _ at: Token) throws {
        let old = prog.globals[name] as? FuncSym
        let f: FuncSym
        if let old = old, !old.defined, !old.isNative {
            old.type = ft; f = old
        } else if let old = old, old.defined, try !isP("{") {
            try expect(";"); return
        } else {
            f = FuncSym(name, ft)
            prog.addFunc(f)
        }
        f.file = at.file; f.line = at.line
        prog.globals[name] = f
        if isNative {
            try expect(";")
            try prog.bindNative(f)
            return
        }
        if try accept(";") { return } // prototype
        if try !isP("{") { try err("expected function body") }
        // parse body
        let saved = (fn, scopes, frameTop)
        fn = f
        scopes = [[:]]
        staticLocals.append([:])
        frameTop = 0
        var offs = [Int](repeating: 0, count: ft.params.count)
        for (i, prm) in ft.params.enumerated() {
            frameTop = (frameTop + 7) & ~7
            offs[i] = frameTop
            if !prm.name.isEmpty { scopes[0][prm.name] = LocalSym(prm.name, prm.type, frameTop) }
            frameTop += 8
        }
        f.paramOffsets = offs
        if ft.varargs {
            f.argcSlot = frameTop; scopes[0]["argc"] = LocalSym("argc", Types.I64, frameTop); frameTop += 8
            f.argvSlot = frameTop; scopes[0]["argv"] = LocalSym("argv", PtrType(Types.I64), frameTop); frameTop += 8
        }
        f.defined = true
        let body = try block()
        f.frameSize = (frameTop + 7) & ~7
        try prog.codegen.compileFunction(f, body)
        fn = saved.0; scopes = saved.1; frameTop = saved.2
        staticLocals.removeLast()
    }

    // ================================================================ statements

    private func block() throws -> Block {
        let at = try tk
        try expect("{")
        scopes.append([:])
        var list: [Stmt] = []
        while try !isP("}") {
            if try tk.kind == .EOF { try err("unexpected end of file in block", at) }
            if let s = try statementOrDecl() { list.append(s) }
        }
        p += 1
        scopes.removeLast()
        return self.at(Block(list), at)
    }

    private func statementOrDecl() throws -> Stmt? {
        if try isTypeStart() && !(tk.kind == .IDENT && peekP(1, "(") && typeNamed(tk.text) == nil && !modifiers.contains(tk.text)) {
            if fn == nil { return try declaration(global: true) }
            return try declaration(global: false)
        }
        return try statement()
    }

    private var stmtDepth = 0

    private func statement() throws -> Stmt? {
        stmtDepth += 1
        defer { stmtDepth -= 1 }
        if stmtDepth > MAX_STMT_DEPTH { try err(DEEP_NESTING) }
        return try statement0()
    }

    private func statement0() throws -> Stmt? {
        try checkStack()
        try checkDepth()
        let at = try tk
        if try tk.kind == .PUNCT {
            switch try tk.text {
            case "{": return try block()
            case ";": p += 1; return NopStmt.shared
            default: break
            }
        }
        if try tk.kind == .IDENT {
            switch try tk.text {
            case "if":
                p += 1; try expect("("); let c = try expr(); try expect(")")
                let t = try statementOrDecl() ?? NopStmt.shared
                var f: Stmt? = nil
                if try isId("else") { p += 1; f = try statementOrDecl() ?? NopStmt.shared }
                return self.at(If(c, t, f), at)
            case "while":
                p += 1; try expect("("); let c = try expr(); try expect(")")
                loopDepth += 1
                let b = try statementOrDecl() ?? NopStmt.shared
                loopDepth -= 1
                return self.at(While(c, b), at)
            case "do":
                p += 1
                loopDepth += 1
                let b = try statementOrDecl() ?? NopStmt.shared
                loopDepth -= 1
                if try !isId("while") { try err("expected 'while'") }
                p += 1; try expect("("); let c = try expr(); try expect(")"); try accept(";")
                return self.at(DoWhile(b, c), at)
            case "for":
                p += 1; try expect("(")
                scopes.append([:])
                let initS: Stmt?
                if try isP(";") { p += 1; initS = nil }
                else if try isTypeStart() { initS = try declaration(global: false) }
                else { let s = ExprStmt(try expr()); try expect(";"); initS = s }
                let c: Expr? = try isP(";") ? nil : expr()
                try expect(";")
                let step: Expr? = try isP(")") ? nil : expr()
                try expect(")")
                loopDepth += 1
                let b = try statementOrDecl() ?? NopStmt.shared
                loopDepth -= 1
                scopes.removeLast()
                return self.at(For(initS, c, step, b), at)
            case "switch": return try switchStmt()
            case "break": p += 1; try expect(";"); return self.at(Break(), at)
            case "continue": p += 1; try expect(";"); return self.at(Continue(), at)
            case "return":
                p += 1
                if try accept(";") { return self.at(Return(nil), at) }
                let e = try expr(); try expect(";")
                return self.at(Return(e), at)
            case "goto": p += 1; let l = try ident(); try expect(";"); return self.at(Goto(l), at)
            case "try":
                p += 1
                let body = try statementOrDecl() ?? NopStmt.shared
                if try !isId("catch") { try err("expected 'catch'") }
                p += 1
                let h = try statementOrDecl() ?? NopStmt.shared
                return self.at(Try(body, h), at)
            case "lock": p += 1; return try statementOrDecl()
            // x86 instructions TempleOS allows as statements; no effect in the sandbox
            case "CLI", "STI", "PUSHFD", "POPFD", "PAUSE", "CLD", "STD", "WBINVD", "INVLPG":
                if try !peekP(1, "(") && !peekP(1, "=") { p += 1; try accept(";"); return nil }
            case "no_warn": while try !isP(";") { p += 1 }; p += 1; return nil
            case "asm": try err("inline x86 assembly (asm {}) is not supported by \(Brand.appName)")
            case "case", "default", "start", "end": if switchDepth > 0 { return try switchLabel() }
            default: break
            }
            // label?
            if try peekP(1, ":") && !scopes.isEmpty {
                let name = try ident(); p += 1
                return self.at(Label(name), at)
            }
        }
        // String statement: "fmt",args;  or  "" fmt,args;
        if try tk.kind == .STR {
            guard let printFn = prog.globals["Print"] as? FuncSym else { try err("Print is not available") }
            let fmt = try tk
            p += 1
            var args: [Expr?] = []
            if try fmt.bytes!.isEmpty && !isP(",") && !isP(";") {
                args.append(try assignExpr())
            } else {
                var b = fmt.bytes!
                // adjacent literal concatenation
                while try tk.kind == .STR { b += try tk.bytes!; p += 1 }
                args.append(self.at(typed(StrLit(b), Types.U8Ptr), fmt))
            }
            while try accept(",") { args.append(try assignExpr()) }
            try expect(";")
            return self.at(ExprStmt(self.at(typed(Call(printFn, nil, printFn.ftype, args), Types.I64), at)), at)
        }
        // '' expr; prints expr as characters: an empty char constant "signals PutChars with
        // variable" (Compiler/PrsExp.HC PrsFunCall; Doc/HolyC.DD: '' drv;)
        if try tk.kind == .CHAR && tk.charLen == 0 && !peekP(1, ";") {
            guard let putChars = prog.globals["PutChars"] as? FuncSym else { try err("PutChars is not available") }
            p += 1
            let args: [Expr?] = [try assignExpr()]
            try expect(";")
            return self.at(ExprStmt(self.at(typed(Call(putChars, nil, putChars.ftype, args), Types.U0), at)), at)
        }
        if try tk.kind == .CHAR && (peekP(1, ";") || peekP(1, ",")) {
            guard let putChars = prog.globals["PutChars"] as? FuncSym else { try err("PutChars is not available") }
            var args: [Expr?] = []
            let ct = try tk
            args.append(self.at(typed(IntLit(ct.ival), Types.I64), ct))
            p += 1
            while try accept(",") {
                args.removeAll(); args.append(try assignExpr())
            }
            try expect(";")
            return self.at(ExprStmt(self.at(typed(Call(putChars, nil, putChars.ftype, args), Types.U0), at)), at)
        }
        let e = try expr()
        try expect(";")
        return self.at(ExprStmt(e), at)
    }

    private func switchStmt() throws -> Stmt {
        let at = try tk
        p += 1
        let unchecked = try isP("[")
        if try !accept("(") { try expect("[") }
        let e = try expr()
        if unchecked { try expect("]") } else { try expect(")") }
        try expect("{")
        switchDepth += 1
        scopes.append([:])
        var body: [Stmt] = []
        nextCase.append(0)
        while try !isP("}") {
            if try tk.kind == .EOF { try err("unexpected end of file in switch", at) }
            if let s = try statementOrDecl() { body.append(s) }
        }
        p += 1
        nextCase.removeLast()
        scopes.removeLast()
        switchDepth -= 1
        return self.at(Switch(e, body, unchecked), at)
    }

    private var nextCase: [Int64] = []

    private func switchLabel() throws -> Stmt {
        let at = try tk
        let w = try ident()
        switch w {
        case "default": try expect(":"); return self.at(CaseLabel(0, 0, true), at)
        case "start": try expect(":"); return self.at(SubStart(), at)
        case "end": try expect(":"); return self.at(SubEnd(), at)
        default: break
        }
        // case
        if try accept(":") {
            let v = nextCase[nextCase.count - 1]
            nextCase[nextCase.count - 1] = v &+ 1
            return self.at(CaseLabel(v, v, false), at)
        }
        let lo = try constInt(try assignExpr())
        var hi = lo
        if try accept("...") { hi = try constInt(try assignExpr()) }
        try expect(":")
        nextCase[nextCase.count - 1] = hi &+ 1
        return self.at(CaseLabel(lo, hi, false), at)
    }

    // ================================================================ expressions

    public func expr() throws -> Expr {
        let at = try tk
        let first = try assignExpr()
        if try !isP(",") { return first }
        var xs = [first]
        while try accept(",") { xs.append(try assignExpr()) }
        return self.at(typed(Comma(xs), xs.last!.type), at)
    }

    private let assignOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

    public func assignExpr() throws -> Expr {
        let at = try tk
        let l = try binary(1)
        if try tk.kind == .PUNCT && assignOps.contains(tk.text) {
            let op = try tk.text
            p += 1
            let r = try assignExpr()
            try checkLvalue(l)
            return self.at(typed(Assign(op, l, r), l.type), at)
        }
        return l
    }

    private func prec(_ t: Token) -> Int {
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

    private func binary(_ minPrec: Int) throws -> Expr {
        var l = try unary()
        while true {
            let pr = try prec(tk)
            if pr < minPrec { return l }
            let at = try tk
            let op = try tk.text
            p += 1
            if pr == 5 || pr == 4 {
                // Chained comparisons: any comparison following another chains, e.g.
                // 2<3==1 is 2<3 && 3==1 (Compiler/PrsExp.HC ICF_PUSH_CMP; all six are IST_CMP).
                var ops = [op]
                var xs = [l, try binary(pr + 1)]
                while true {
                    let np = try prec(tk)
                    if !((np == 4 || np == 5) && np >= minPrec) { break }
                    ops.append(try tk.text); p += 1
                    xs.append(try binary(np + 1))
                }
                l = try ops.count == 1 ? mkBinary(op, xs[0], xs[1], at) : self.at(typed(Chain(ops, xs), Types.I64), at)
                continue
            }
            if op == "`" { l = try mkBinary(op, l, try powerOperand(), at); continue }
            let r = try binary(pr + 1)
            l = try pr <= 3 ? self.at(typed(Logical(op, l, r), Types.I64), at) : mkBinary(op, l, r, at)
        }
    }

    /** Right operand of ` : right associative among ` only (Compiler/CInit.HC ASSOCF_RIGHT). */
    private func powerOperand() throws -> Expr {
        let at = try tk
        let b = try binary(12)
        if try tk.kind == .PUNCT && tk.text == "`" { p += 1; return try mkBinary("`", b, try powerOperand(), at) }
        return b
    }

    public func mkBinary(_ op: String, _ l: Expr, _ r: Expr, _ at: Token) throws -> Expr {
        let lt: HType = l.type
        let rt: HType = r.type
        let type: HType
        switch op {
        case "<", ">", "<=", ">=", "==", "!=": type = Types.I64
        case "+", "-":
            if Types.isPtrLike(lt) && Types.isPtrLike(rt) && op == "-" { type = Types.I64 }
            else if Types.isPtrLike(lt) { type = decay(lt) }
            else if Types.isPtrLike(rt) && op == "+" { type = decay(rt) }
            else if lt is F64Type || rt is F64Type { type = Types.F64 }
            else if Types.isUnsigned64(lt) || Types.isUnsigned64(rt) { type = Types.U64 }
            else { type = Types.I64 }
        case "`": type = Types.F64 // always F64 (Compiler/OptPass012.HC IC_POWER)
        case "*", "/", "%":
            if lt is F64Type || rt is F64Type { type = Types.F64 }
            else if Types.isUnsigned64(lt) || Types.isUnsigned64(rt) { type = Types.U64 }
            else { type = Types.I64 }
        case "<<", ">>": type = lt is F64Type ? Types.I64 : (Types.isUnsigned64(lt) ? Types.U64 : Types.I64)
        default: type = (Types.isUnsigned64(lt) || Types.isUnsigned64(rt)) ? Types.U64 : Types.I64 // & | ^
        }
        if ((lt as? ClassType).map { $0.valueType == nil } ?? false) || ((rt as? ClassType).map { $0.valueType == nil } ?? false) {
            try err("invalid operands to '\(op)' (class value)", at)
        }
        return self.at(typed(Binary(op, l, r), type), at)
    }

    private func decay(_ t: HType) -> HType { (t as? ArrType).map { PtrType($0.elem) } ?? t }

    private func unary() throws -> Expr {
        try checkStack()
        try checkDepth()
        let at = try tk
        if try tk.kind == .PUNCT {
            switch try tk.text {
            case "-":
                p += 1
                var e = try unary()
                // -x`y is -(x`y) (Compiler/PrsExp.HC PE_DO_UNARY_OP special case)
                if try tk.kind == .PUNCT && tk.text == "`" { let pa = try tk; p += 1; e = try mkBinary("`", e, try powerOperand(), pa) }
                if let i = e as? IntLit { return self.at(typed(IntLit(0 &- i.v), Types.I64), at) }
                if let f = e as? FloatLit { return self.at(typed(FloatLit(-f.v), Types.F64), at) }
                return self.at(typed(Unary("-", e), e.type is F64Type ? Types.F64 : (Types.isUnsigned64(e.type) ? Types.U64 : Types.I64)), at)
            case "+": p += 1; return try unary()
            case "!": p += 1; let e = try unary(); return self.at(typed(Unary("!", e), Types.I64), at)
            case "~": p += 1; let e = try unary(); return self.at(typed(Unary("~", e), Types.isUnsigned64(e.type) ? Types.U64 : Types.I64), at)
            case "*":
                p += 1
                let e = try unary()
                return try deref(e, at)
            case "&":
                p += 1
                // &Func => function address
                if try tk.kind == .IDENT && lookupLocal(tk.text) == nil {
                    let f = try prog.globals[tk.text] as? FuncSym
                    if let f = f, try !peekP(1, "(") {
                        p += 1
                        return self.at(typed(FuncAddr(f), PtrType(f.ftype)), at)
                    }
                }
                let e = try unary()
                if let c = e as? Call, c.args.isEmpty, let cf = c.fn { // &Func parsed as no-paren call
                    return self.at(typed(FuncAddr(cf), PtrType(cf.ftype)), at)
                }
                if e is FuncAddr { return e }
                try checkLvalue(e)
                let et: HType = e.type
                let t: HType = (et as? ArrType).map { PtrType($0.elem) } ?? PtrType(et)
                return self.at(typed(AddrOf(e), t), at)
            case "++", "--":
                let d = try tk.text == "++" ? 1 : -1
                p += 1
                let e = try unary()
                try checkLvalue(e)
                return self.at(typed(IncDec(e, d, false), e.type), at)
            default: break
            }
        }
        if try tk.kind == .IDENT && (tk.text == "sizeof" || tk.text == "offset") { return try sizeofExpr() }
        return try postfix(try primary())
    }

    private func deref(_ e: Expr, _ at: Token) throws -> Expr {
        let t: HType = e.type
        // On TempleOS (reference VM) a non-pointer is used as an address and read with its own type:
        // *I64 reads 8 bytes, *U8 one, *I32 four; *F64 uses the F64's bits. A class variable's value
        // is its first 8 bytes, so *classvar reads the I64 those bytes point to (ToTheFront's
        // while (tmpi!=*indirect_head)). docs/fidelity-audit/data/vm-observations.json
        if let c = t as? ClassType, c.valueType == nil {
            let first = self.at(typed(MemberAccess(e, 0, false), Types.I64), at)
            return self.at(typed(Deref(first), Types.I64), at)
        }
        let target: HType
        if let pt = t as? PtrType { target = pt.target }
        else if let a = t as? ArrType { target = a.elem }
        else if t is IntType || t is F64Type { target = t }
        else if let c = t as? ClassType, let v = c.valueType { target = v }
        else { try err("cannot dereference \(t.name)", at) }
        if target is FuncType { return e } // (*fp)(...) == fp(...)
        return self.at(typed(Deref(e), target), at)
    }

    private func sizeofExpr() throws -> Expr {
        let at = try tk
        let isOffset = try tk.text == "offset"
        p += 1
        let paren = try accept("(")
        let result: Int64
        if try tk.kind == .IDENT && typeNamed(tk.text) != nil && lookupLocal(tk.text) == nil && !(prog.globals[tk.text] is GlobalSym) {
            var t: HType = typeNamed(try ident())!
            if try accept(".") {
                let mname = try ident()
                guard let cls = t as? ClassType else { try err("not a class", at) }
                guard let m = cls.find(mname) else { try err("no member '\(mname)' in \(cls.name)", at) }
                result = isOffset ? Int64(m.offset) : Int64(m.type.size)
            } else {
                while try accept("*") { t = PtrType(t) }
                result = Int64(t.size)
            }
        } else {
            if isOffset { try err("offset() needs Class.member", at) }
            let e = try paren ? expr() : unary()
            result = Int64(e.type.size)
        }
        if paren { try expect(")") }
        return self.at(typed(IntLit(result), Types.I64), at)
    }

    private func primary() throws -> Expr {
        let at = try tk
        switch at.kind {
        case .INT: p += 1; return self.at(typed(IntLit(at.ival), at.ival < 0 ? Types.U64 : Types.I64), at)
        case .CHAR: p += 1; return self.at(typed(IntLit(at.ival), Types.I64), at)
        case .FLOAT: p += 1; return self.at(typed(FloatLit(at.fval), Types.F64), at)
        case .STR:
            var b = at.bytes!
            p += 1
            while try tk.kind == .STR { b += try tk.bytes!; p += 1 }
            return self.at(typed(StrLit(b), Types.U8Ptr), at)
        case .INS_BIN: p += 1; return self.at(typed(BinLit(at.bytes!), Types.U8Ptr), at)
        case .PUNCT:
            if try accept("(") {
                let e = try expr()
                try expect(")")
                return e
            }
            try err("unexpected '\(tk.description)'")
        case .IDENT:
            let name = at.text
            p += 1
            if let l = lookupLocal(name) { return self.at(typed(VarRef(l), l.type), at) }
            if let g = staticLocals.last?[name] { return self.at(typed(VarRef(g), g.type), at) }
            let g = prog.globals[name]
            if let g = g as? FuncSym {
                if try isP("(") { return try callArgs(g, nil, g.ftype, at) }
                return self.at(typed(Call(g, nil, g.ftype, []), g.ftype.ret), at)
            }
            if let g = g as? GlobalSym { if name == "acd" {try prog.requireService("dictionary")};return self.at(typed(VarRef(g), g.type), at) }
            switch name {
            case "lastclass": return self.at(typed(StrLit(latin1("@lastclass")), Types.U8Ptr), at)
            case "TRUE": return self.at(typed(IntLit(1), Types.I64), at)
            case "FALSE", "NULL": return self.at(typed(IntLit(0), Types.I64), at)
            default: break
            }
            try err("undefined identifier '\(name)'", at)
        case .EOF: try err("unexpected end of file")
        }
    }

    private func postfix(_ e0: Expr) throws -> Expr {
        var e = e0
        while true {
            try checkDepth()
            let at = try tk
            if try tk.kind != .PUNCT { return e }
            switch try tk.text {
            case "[":
                p += 1
                let idx = try expr()
                try expect("]")
                let bt: HType = e.type
                let elem: HType
                if let a = bt as? ArrType { elem = a.elem }
                else if let pt = bt as? PtrType { elem = pt.target }
                else { try err("cannot index \(bt.name)", at) }
                e = self.at(typed(IndexExpr(e, idx), elem), at)
            case ".", "->":
                let arrow = try tk.text == "->"
                p += 1
                let mname = try ident()
                e = try member(e, mname, arrow, at)
            case "(":
                // postfix type cast?
                if try p + 1 < toks.size && isTypeStart(toks[p + 1]) && !modifiers.contains(toks[p + 1].text) {
                    p += 1
                    var t = try baseType()
                    while try accept("*") { t = PtrType(t) }
                    try expect(")")
                    e = self.at(typed(Cast(e), t), at)
                    continue
                }
                guard let ft = funcTypeOf(e.type) else { try err("called object is not a function", at) }
                e = try callArgs(nil, e, ft, at)
            case "++", "--":
                let d = try tk.text == "++" ? 1 : -1
                p += 1
                try checkLvalue(e)
                e = self.at(typed(IncDec(e, d, true), e.type), at)
            default: return e
            }
        }
    }

    private func funcTypeOf(_ t: HType) -> FuncType? {
        if let f = t as? FuncType { return f }
        if let pt = t as? PtrType { return (pt.target as? FuncType) ?? ((pt.target as? PtrType)?.target as? FuncType) }
        return nil
    }

    private func member(_ base: Expr, _ name: String, _ arrow: Bool, _ at: Token) throws -> Expr {
        var b = base
        var bt: HType = b.type
        if arrow {
            if let pt = bt as? PtrType { bt = pt.target }
            else if let a = bt as? ArrType { bt = a.elem }
            else { try err("'->' on non-pointer \(bt.name)", at) }
        }
        if let ct = bt as? ClassType {
            guard let m = ct.find(name) else { try err("no member '\(name)' in \(ct.name)", at) }
            if !arrow { b = try lvalueOrTemp(b, at) }
            return self.at(typed(MemberAccess(b, m.offset, arrow), m.type), at)
        }
        guard let it0 = Types.asInt(bt) ?? (bt is F64Type ? Types.I64 : nil) else { try err("member '\(name)' on \(bt.name)", at) }
        guard let sub = Types.intSubMember(it0, name) else { try err("no member '\(name)' in \(bt.name)", at) }
        if !arrow { b = try lvalueOrTemp(b, at) }
        return self.at(typed(MemberAccess(b, 0, arrow), sub), at)
    }

    /** Sub-member access needs an address; spill rvalues into a hidden temporary. */
    private func lvalueOrTemp(_ e: Expr, _ at: Token) throws -> Expr {
        if isLvalue(e) { return e }
        let name = "$tmp\(tmpCounter)"
        tmpCounter += 1
        let ref: Expr
        if !scopes.isEmpty {
            let l = declareLocal(name, e.type, at)
            ref = typed(VarRef(l), e.type)
        } else {
            let g = GlobalSym(name, e.type, try prog.allocGlobal(max(e.type.size, 8)))
            ref = typed(VarRef(g), e.type)
        }
        self.at(ref, at)
        return self.at(typed(Comma([self.at(typed(Assign("=", ref, e), e.type), at), ref]), e.type), at)
    }

    private func isLvalue(_ e: Expr) -> Bool {
        if stackRemaining() < STACK_RESERVE { return false }
        switch e {
        case let v as VarRef: return !(v.sym is FuncSym)
        case is IndexExpr, is Deref: return true
        case is MemberAccess: return true
        case let c as Comma: return isLvalue(c.xs.last!)
        case let c as Cast: return isLvalue(c.e)
        default: return false
        }
    }

    private func checkLvalue(_ e: Expr) throws {
        if !isLvalue(e) { throw CompileError("expression is not assignable", e.file, e.line) }
    }

    private func callArgs(_ fsym: FuncSym?, _ callee: Expr?, _ ft: FuncType, _ at: Token) throws -> Expr {
        try expect("(")
        var args: [Expr?] = []
        if try !accept(")") {
            while true {
                if try isP(",") { args.append(nil) }
                else if try isP(")") { args.append(nil) }
                else { args.append(try assignExpr()) }
                if try accept(")") { break }
                try expect(",")
            }
        }
        for (i, param) in ft.params.enumerated() {
            if i < args.count && args[i] != nil { continue }
            guard let d = param.defaultExpr as? StrLit, d.bytes == latin1("@lastclass") else { continue }
            let previous = i > 0 && i - 1 < args.count ? args[i - 1]?.type : nil
            let type = (previous as? PtrType)?.target ?? previous
            while args.count <= i { args.append(nil) }
            args[i] = self.at(typed(StrLit(latin1((type as? ClassType)?.name ?? "")), Types.U8Ptr), at)
        }
        return self.at(typed(Call(fsym, callee, ft, args), ft.ret), at)
    }

    // ================================================================ constants

    /** Constant value of [e]; like TempleOS JIT mode, non-constant expressions are run at compile time. */
    public func constInt(_ e: Expr) throws -> Int64 {
        if let v = ConstFold.int(e) { return v }
        if let ev = prog.evalAtCompileTime, let v = try ev(e) { return v }
        throw CompileError("constant expression expected", e.file, e.line)
    }
}

/** Compile-time folding of integer constant expressions. */
public enum ConstFold {
    public static func int(_ e: Expr) -> Int64? {
        if stackRemaining() < STACK_RESERVE { return nil }
        switch e {
        case let i as IntLit: return i.v
        case let f as FloatLit: return toLong(f.v)
        case let u as Unary:
            guard let v = int(u.e) else { return nil }
            switch u.op {
            case "-": return 0 &- v
            case "~": return ~v
            default: return v == 0 ? 1 : 0
            }
        case let c as Cast: return int(c.e)
        case let bn as Binary:
            let l = int(bn.l); let r = int(bn.r)
            guard let l = l, let r = r, !(bn.type is F64Type), !(bn.l.type is F64Type), !(bn.r.type is F64Type),
                  !Types.isPtrLike(bn.l.type), !Types.isPtrLike(bn.r.type) else { return nil }
            switch bn.op {
            case "+": return l &+ r
            case "-": return l &- r
            case "*": return l &* r
            case "/": return r == 0 ? nil : sdiv(l, r)
            case "%": return r == 0 ? nil : smod(l, r)
            case "&": return l & r
            case "|": return l | r
            case "^": return l ^ r
            case "<<": return l &<< r
            case ">>": return l &>> r
            case "<": return b(l < r)
            case ">": return b(l > r)
            case "<=": return b(l <= r)
            case ">=": return b(l >= r)
            case "==": return b(l == r)
            case "!=": return b(l != r)
            case "`":
                var x: Int64 = 1
                let n = max(Int(Int32(truncatingIfNeeded: r)), 0)
                for _ in 0..<n { x = x &* l }
                return x
            default: return nil
            }
        case let lg as Logical:
            let l = int(lg.l); let r = int(lg.r)
            guard let l = l, let r = r else { return nil }
            switch lg.op {
            case "&&": return b(l != 0 && r != 0)
            case "||": return b(l != 0 || r != 0)
            default: return b((l != 0) != (r != 0))
            }
        default: return nil
        }
    }

    public static func float(_ e: Expr) -> Double? {
        if stackRemaining() < STACK_RESERVE { return nil }
        switch e {
        case let f as FloatLit: return f.v
        case let i as IntLit: return Double(i.v)
        case let u as Unary: return u.op == "-" ? float(u.e).map { -$0 } : nil
        case let bn as Binary:
            let l = float(bn.l); let r = float(bn.r)
            guard let l = l, let r = r else { return nil }
            switch bn.op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return l / r
            default: return nil
            }
        default: return nil
        }
    }

    private static func b(_ v: Bool) -> Int64 { v ? 1 : 0 }

    /** Kotlin Double.toLong(): truncates, saturates, NaN -> 0. */
    private static func toLong(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        if x >= 9.223372036854775807E18 { return Int64.max }
        if x <= -9.223372036854775808E18 { return Int64.min }
        return Int64(x)
    }
}
