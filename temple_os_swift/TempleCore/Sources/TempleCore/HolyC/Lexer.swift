import Foundation

/** See Lexer.expandBudget (Kotlin MAX_EXPANSION). */
public let MAX_EXPANSION = 1_000_000

// Port of holyc/Lexer.kt. Kotlin `enum class T` is `TokKind` here.

/** Kotlin `MutableMap<String, List<Token>>` shared by reference between the kernel and lexers. */
public typealias Defines = Ref<[String: [Token]]>

public enum TokKind { case IDENT, INT, FLOAT, STR, CHAR, PUNCT, INS_BIN, EOF }

/** Random-access view of a (possibly still being lexed) token stream. */
public protocol TokenSource: AnyObject {
    /** Kotlin `operator fun get(i)`; lexing more input can raise a CompileError. */
    subscript(i: Int) -> Token { get throws }
    var size: Int { get }
}

extension TokenSource {
    public func get(_ i: Int) throws -> Token { try self[i] }
}

public final class Token: CustomStringConvertible {
    public let kind: TokKind
    public let text: String          // identifier / punctuator text
    public let file: String
    public let line: Int
    public var ival: Int64 = 0       // INT and CHAR value
    public var fval: Double = 0.0
    public var bytes: [UInt8]? = nil // STR contents (without NUL), INS_BIN data
    public var charLen = 0           // number of chars in a CHAR literal
    /** True when the token was the first on its source line (used for statement-level heuristics). */
    public var lineStart = false
    /** Set on identifiers that came out of a macro expansion. */
    public var hidden: Set<String>? = nil

    public init(_ kind: TokKind, _ text: String, _ file: String, _ line: Int) {
        self.kind = kind; self.text = text; self.file = file; self.line = line
    }

    /** Kotlin toString(). */
    public var description: String {
        switch kind {
        case .STR: return "\"" + latin1(bytes!) + "\""
        case .INT: return String(ival)
        case .EOF: return "end of file"
        default: return text
        }
    }
}

// Byte constants (Kotlin 'x'.code)
private let cNL = 10, cSP = 32, cTAB = 9, cCR = 13
private let cSLASH = 47, cSTAR = 42, cDOLLAR = 36, cQUOTE = 34, cAPOS = 39, cBSLASH = 92
private let c0 = 48, c1 = 49, c7 = 55, c9 = 57, cDOT = 46

/** Kotlin `Character.digit(c, 16)` for a Latin-1 code. */
private func hexDigit(_ c: Int) -> Int {
    if c >= 48 && c <= 57 { return c - 48 }
    if c >= 65 && c <= 70 { return c - 55 }
    if c >= 97 && c <= 102 { return c - 87 }
    return -1
}

/** Kotlin `s.substringBeforeLast(c, missing)`. */
private func substringBeforeLast(_ s: String, _ c: Unicode.Scalar, _ missing: String) -> String {
    let u = Array(s.unicodeScalars)
    guard let i = u.lastIndex(of: c) else { return missing }
    var r = String.UnicodeScalarView(); r.append(contentsOf: u[0..<i])
    return String(r)
}

/**
 * HolyC tokenizer with the TempleOS preprocessor integrated. Operates on raw
 * DolDoc source bytes (see Source.swift for the DolDoc rules).
 */
public final class Lexer {
    private final class Input {
        let src: SourceFile
        let dir: String
        var pos = 0
        var line = 1
        var atLineStart = true
        init(_ src: SourceFile, _ dir: String) { self.src = src; self.dir = dir }
    }

    private let provider: SourceProvider?
    private let defines: Defines
    /** Answers `#ifdef` for non-macro symbols (functions, globals, classes). */
    private let symbolDefined: (String) -> Bool

    public init(_ provider: SourceProvider?, _ defines: Defines = Ref([:]), _ symbolDefined: @escaping (String) -> Bool = { _ in false }) {
        self.provider = provider
        self.defines = defines
        self.symbolDefined = symbolDefined
    }

    private var inputs: [Input] = []
    fileprivate var out: [Token] = []
    // Conditional compilation stack: each entry = (currently active, some branch taken)
    private var conds: [[Bool]] = []

    public func tokenize(_ src: SourceFile, _ dir: String) throws -> [Token] {
        let s = stream(src, dir)
        var i = 0
        while try s[i].kind != .EOF { i += 1 }
        return out
    }

    fileprivate var eof = false
    private var mainName = ""

    /**
     * Lazily lexed tokens. TempleOS compiles (and the kernel runs) top-level code
     * as it goes, so macros defined at run time (DefinePrint) apply to later code.
     */
    public func stream(_ src: SourceFile, _ dir: String) -> TokenSource {
        inputs.append(Input(src, dir))
        mainName = src.name
        return LexerTokenSource(self)
    }

    fileprivate func pull() throws {
        let before = out.count
        while out.count == before {
            guard let t = try rawNext() else {
                if !conds.isEmpty { throw CompileError("missing #endif", mainName, 0) }
                out.append(Token(.EOF, "", mainName, 0))
                eof = true
                return
            }
            try handle(t)
        }
    }

    private func active() -> Bool { conds.isEmpty || conds[conds.count - 1][0] }

    private func handle(_ t: Token) throws {
        if t.kind == .PUNCT && t.text == "#" {
            try directive(t)
            return
        }
        if !active() { return }
        if t.kind == .IDENT {
            switch t.text {
            case "__DIR__", "__FILE__":
                let f = t.file
                let v = t.text == "__FILE__" ? f : substringBeforeLast(f, "/", "C:/")
                let n = Token(.STR, "", t.file, t.line); n.bytes = latin1(v)
                out.append(n); return
            case "__LINE__":
                let n = Token(.INT, "", t.file, t.line); n.ival = Int64(t.line)
                out.append(n); return
            default: break
            }
            expandBudget = MAX_EXPANSION
            try expand(t, [], &out)
            return
        }
        out.append(t)
    }

    /** Tokens one macro use may produce: doubling #define chains would otherwise hang the compiler. */
    private var expandBudget = MAX_EXPANSION

    private func expand(_ t: Token, _ hide: Set<String>, _ sink: inout [Token]) throws {
        expandBudget -= 1
        if expandBudget < 0 { throw CompileError("macro expansion too large", t.file, t.line) }
        let body = defines.value[t.text]
        if body == nil || hide.contains(t.text) || (t.hidden?.contains(t.text) == true) {
            sink.append(t); return
        }
        let h = hide.union([t.text]).union(t.hidden ?? [])
        for b in body! {
            let c = copyTok(b, t)
            if c.kind == .IDENT { try expand(c, h, &sink) } else { sink.append(c) }
        }
    }

    private func copyTok(_ b: Token, _ at: Token) -> Token {
        let c = Token(b.kind, b.text, at.file, at.line)
        c.ival = b.ival; c.fval = b.fval; c.bytes = b.bytes; c.charLen = b.charLen
        c.lineStart = false
        return c
    }

    // ---------------------------------------------------------------- directives

    private func restOfLine() throws -> [Token] {
        let inp = inputs[inputs.count - 1]
        var res: [Token] = []
        let b = inp.src.text
        while true {
            skipSpaces(inp, stopAtNewline: true)
            // backslash-newline continues a directive on the next line (Apps/KeepAway)
            if inp.pos < b.count && Int(b[inp.pos]) == cBSLASH {
                var q = inp.pos + 1
                while q < b.count && (Int(b[q]) == cSP || Int(b[q]) == cTAB || Int(b[q]) == cCR) { q += 1 }
                if q < b.count && Int(b[q]) == cNL { inp.pos = q + 1; inp.line += 1; continue }
            }
            if inp.pos >= b.count || Int(b[inp.pos]) == cNL { break }
            guard let t = try lexOne(inp) else { break }
            res.append(t)
        }
        return res
    }

    private func directive(_ hash: Token) throws {
        let inp = inputs[inputs.count - 1]
        skipSpaces(inp, stopAtNewline: true)
        guard let nameTok = try lexOne(inp) else { throw CompileError("bad directive", hash.file, hash.line) }
        let name = nameTok.text
        switch name {
        case "ifdef", "ifndef":
            let id = try restOfLine().first?.text ?? ""
            let def = defines.value[id] != nil || symbolDefined(id)
            pushCond(name == "ifdef" ? def : !def)
        case "if":
            let toks = try restOfLine()
            pushCond(active() ? (try evalCond(toks, hash)) : false)
        case "ifjit": _ = try restOfLine(); pushCond(true)
        case "ifaot": _ = try restOfLine(); pushCond(false)
        case "else":
            _ = try restOfLine()
            if conds.isEmpty { throw CompileError("#else without #if", hash.file, hash.line) }
            let parentActive = conds.count < 2 || conds[conds.count - 2][0]
            let ci = conds.count - 1
            conds[ci][0] = parentActive && !conds[ci][1]
            conds[ci][1] = true
        case "endif":
            _ = try restOfLine()
            if conds.isEmpty { throw CompileError("#endif without #if", hash.file, hash.line) }
            conds.removeLast()
        default:
            if !active() { _ = try restOfLine(); return }
            switch name {
            case "define":
                let toks = try restOfLine()
                if toks.isEmpty { throw CompileError("#define needs a name", hash.file, hash.line) }
                defines.value[toks[0].text] = Array(toks[1...])
            case "undef":
                if let t = try restOfLine().first { defines.value.removeValue(forKey: t.text) }
            case "include":
                let toks = try restOfLine()
                let f = toks.first
                if f == nil || f!.kind != .STR { throw CompileError("#include needs a \"file\"", hash.file, hash.line) }
                try include(latin1(f!.bytes!), hash)
            case "help_index", "help_file", "assert", "pragma": _ = try restOfLine()
            case "exe": throw CompileError(
                "#exe {} (compile-time code execution) is not supported by \(Brand.appName)",
                hash.file, hash.line)
            default: throw CompileError("unknown directive #\(name)", hash.file, hash.line)
            }
        }
    }

    private func pushCond(_ v: Bool) {
        let parentActive = active()
        conds.append([parentActive && v, v])
    }

    private func include(_ path: String, _ at: Token) throws {
        if inputs.count > 16 { throw CompileError("#include nested too deeply", at.file, at.line) }
        let cur = inputs[inputs.count - 1]
        let full = Lexer.resolvePath(cur.dir, path)
        // TempleOS adds a default extension when none is given
        let candidates = full.substringAfterLast("/").unicodeScalars.contains(".") ? [full, "\(full).Z"]
            : ["\(full).HC", "\(full).HH", "\(full).HC.Z", full]
        var data: [UInt8]? = nil
        var found = full
        for c in candidates { data = provider?.read(c); if data != nil { found = c; break } }
        guard let bytes = data else { throw CompileError("#include file not found: \(path)", at.file, at.line) }
        let dir = substringBeforeLast(found, "/", "C:")
        inputs.append(Input(SourceFile.parse(found, bytes), dir))
    }

    private func evalCond(_ toks: [Token], _ at: Token) throws -> Bool {
        var expanded: [Token] = []
        for t in toks { if t.kind == .IDENT { expandBudget = MAX_EXPANSION; try expand(t, [], &expanded) } else { expanded.append(t) } }
        do {
            return try ConstEval(expanded).eval() != 0
        } catch {
            throw CompileError("cannot evaluate #if expression", at.file, at.line)
        }
    }

    // ---------------------------------------------------------------- raw lexing

    /** Next raw token across include boundaries, or nil at end of the main file. */
    private func rawNext() throws -> Token? {
        while !inputs.isEmpty {
            let inp = inputs[inputs.count - 1]
            if let t = try lexOne(inp) { return t }
            inputs.removeLast()
        }
        return nil
    }

    private func skipSpaces(_ inp: Input, stopAtNewline: Bool) {
        let b = inp.src.text
        while inp.pos < b.count {
            let c = Int(b[inp.pos])
            if c == cNL {
                if stopAtNewline { return }
                inp.line += 1; inp.pos += 1; inp.atLineStart = true
            } else if c == cSP || c == cTAB || c == cCR || c == 0x0C || c == 5 || c == 31 {
                inp.pos += 1
            } else if c == cSLASH && inp.pos + 1 < b.count && Int(b[inp.pos + 1]) == cSLASH {
                while inp.pos < b.count && Int(b[inp.pos]) != cNL { inp.pos += 1 }
            } else if c == cSLASH && inp.pos + 1 < b.count && Int(b[inp.pos + 1]) == cSTAR {
                inp.pos += 2
                var depth = 1 // TempleOS allows nested /* */ comments
                while inp.pos < b.count && depth > 0 {
                    let d = Int(Int8(bitPattern: b[inp.pos])) // Kotlin b[p].toInt() (signed)
                    if d == cNL { inp.line += 1 }
                    if d == cSTAR && inp.pos + 1 < b.count && Int(b[inp.pos + 1]) == cSLASH {
                        depth -= 1; inp.pos += 2; continue
                    }
                    if d == cSLASH && inp.pos + 1 < b.count && Int(b[inp.pos + 1]) == cSTAR {
                        depth += 1; inp.pos += 2; continue
                    }
                    inp.pos += 1
                }
            } else if c == cDOLLAR {
                // DolDoc command in code context
                let end = dollarEnd(b, inp.pos)
                if end < 0 { inp.pos += 1; continue }
                if end == inp.pos + 1 { inp.pos += 2; continue } // "$$" in code: ignore
                let cmd = latin1(b, inp.pos + 1, end - inp.pos - 1)
                let code = cmd.take(2)
                if code == "IB" || code == "IS" || code == "TX" { return } // handled by lexOne
                inp.pos = end + 1
            } else {
                return
            }
        }
    }

    /** Index of the `$` closing a DolDoc command starting at [p], or -1. */
    private func dollarEnd(_ b: [UInt8], _ p: Int) -> Int {
        var i = p + 1
        var inQ = false
        while i < b.count {
            let c = Int(b[i])
            if c == cNL { return -1 }
            if c == cQUOTE { inQ = !inQ }
            else if c == cBSLASH && inQ { i += 1 }
            else if c == cDOLLAR && !inQ { return i }
            i += 1
        }
        return -1
    }

    private func lexOne(_ inp: Input) throws -> Token? {
        skipSpaces(inp, stopAtNewline: false)
        let b = inp.src.text
        if inp.pos >= b.count { return nil }
        let start = inp.pos
        let c = Int(b[start])
        let first = inp.atLineStart
        inp.atLineStart = false
        let tok: Token
        if c == cDOLLAR {
            tok = try dollarToken(inp)
        } else if isIdStart(c) {
            var p = start + 1
            var seg = start
            var name: [UInt8] = []
            while true {
                while p < b.count && isIdChar(Int(b[p])) { p += 1 }
                // A DolDoc formatting command inside an identifier (e.g. θ$SY,3$n$SY,0$
                // in Demo/Graphics/LightTable.HC) is not part of the text TempleOS lexes:
                // skip it and continue the identifier.
                if p < b.count && Int(b[p]) == cDOLLAR {
                    let end = dollarEnd(b, p)
                    if end > p + 1 && end + 1 < b.count && isIdChar(Int(b[end + 1])) {
                        let code = latin1(b, p + 1, min(2, end - p - 1))
                        if code != "IB" && code != "IS" && code != "TX" {
                            name.append(contentsOf: b[seg..<p]); p = end + 1; seg = p; continue
                        }
                    }
                }
                break
            }
            name.append(contentsOf: b[seg..<p])
            tok = Token(.IDENT, latin1(name), inp.src.name, inp.line)
            inp.pos = p
        } else if (c >= c0 && c <= c9) || (c == cDOT && start + 1 < b.count && Int(b[start + 1]) >= c0 && Int(b[start + 1]) <= c9) {
            tok = try number(inp)
        } else if c == cQUOTE {
            tok = try string(inp)
        } else if c == cAPOS {
            tok = try charLit(inp)
        } else {
            tok = try punct(inp)
        }
        tok.lineStart = first
        return tok
    }

    /** Kotlin `Regex("BI=(\\d+)").find(cmd)?.groupValues?.get(1)?.toInt()`. */
    private static func findBI(_ cmd: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < cmd.count {
            if cmd[i] == 66 && cmd[i + 1] == 73 && cmd[i + 2] == 61 && cmd[i + 3] >= 48 && cmd[i + 3] <= 57 {
                var j = i + 3
                while j < cmd.count && cmd[j] >= 48 && cmd[j] <= 57 { j += 1 }
                return Int(latin1(cmd, i + 3, j - i - 3)).flatMap { $0 >= Int(Int32.min) && $0 <= Int(Int32.max) ? $0 : nil }
            }
            i += 1
        }
        return nil
    }

    /** Kotlin `Regex("^TX[^\"]*\"((?:[^\"\\\\]|\\\\.)*)\"").find(cmd)?.groupValues?.get(1)`. */
    private static func findTX(_ cmd: [UInt8]) -> String? {
        if cmd.count < 2 || cmd[0] != 84 || cmd[1] != 88 { return nil }
        var i = 2
        while i < cmd.count && Int(cmd[i]) != cQUOTE { i += 1 }
        if i >= cmd.count { return nil }
        i += 1
        let s = i
        while i < cmd.count {
            let c = Int(cmd[i])
            if c == cQUOTE { return latin1(cmd, s, i - s) }
            if c == cBSLASH {
                // `.` does not match Java line terminators (\n, \r, U+0085)
                if i + 1 < cmd.count, cmd[i + 1] != 10, cmd[i + 1] != 13, cmd[i + 1] != 0x85 { i += 2; continue }
                return nil
            }
            i += 1
        }
        return nil
    }

    /** DolDoc BP imports by number or tag through the sandboxed source provider. */
    private func binaryData(_ inp: Input, _ cmd: String, _ bi: Int?) -> [UInt8]? {
        let pattern = #"BP="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let range = Range(match.range(at: 1), in: cmd) else { return bi.flatMap { inp.src.bins[$0] } }
        let bp = String(cmd[range])
        guard let comma = bp.lastIndex(of: ",") else { return nil }
        let full = Lexer.resolvePath(inp.dir, String(bp[..<comma])), ref = String(bp[bp.index(after: comma)...])
        let candidates = full.substringAfterLast("/").contains(".") ? [full,full + ".Z"] : [full + ".HC",full + ".HH",full + ".HC.Z",full]
        for path in candidates {
            guard let raw = provider?.read(path) else { continue }
            let source = SourceFile.parse(path,raw)
            var num = Int(ref)
            if num == nil {
                let text = latin1(source.text)
                let tagPattern = #"\$SP[^\n$]*,""# + NSRegularExpression.escapedPattern(for: ref) + #""[^\n$]*BI=(\d+)"#
                if let re = try? NSRegularExpression(pattern:tagPattern),let m = re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let r = Range(m.range(at:1),in:text) { num = Int(text[r]) }
            }
            return num.flatMap { source.bins[$0] }
        }
        return nil
    }

    private func dollarToken(_ inp: Input) throws -> Token {
        let b = inp.src.text
        let end = dollarEnd(b, inp.pos)
        let cmdBytes = Array(b[(inp.pos + 1)..<end])
        let cmd = latin1(cmdBytes)
        inp.pos = end + 1
        let code = cmd.take(2)
        let bi = Lexer.findBI(cmdBytes)
        switch code {
        case "IB":
            guard let data = binaryData(inp,cmd,bi) else {
                throw CompileError("missing binary attachment in $\(cmd)$", inp.src.name, inp.line)
            }
            let t = Token(.INS_BIN, "<bin>", inp.src.name, inp.line); t.bytes = data
            return t
        case "IS":
            let data = binaryData(inp,cmd,bi)
            let t = Token(.INT, "", inp.src.name, inp.line); t.ival = Int64(data?.count ?? 0)
            return t
        default: // TX: literal text; tokenise it in place
            let txt = Lexer.findTX(cmdBytes) ?? ""
            let sub = try Lexer(nil, defines).tokenizeFragment(txt, inp.src.name, inp.line)
            // Only single-token text entries are meaningful in code; otherwise return first.
            return sub.first ?? Token(.PUNCT, ";", inp.src.name, inp.line)
        }
    }

    public func tokenizeFragment(_ s: String, _ file: String, _ line: Int) throws -> [Token] {
        let inp = Input(SourceFile.ofString(file, s), "")
        inp.line = line
        var res: [Token] = []
        while true { guard let t = try lexOne(inp) else { break }; res.append(t) }
        return res
    }

    private func isIdStart(_ c: Int) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128 }
    private func isIdChar(_ c: Int) -> Bool { isIdStart(c) || (c >= c0 && c <= c9) }

    @inline(__always) private func isDigit(_ x: UInt8) -> Bool { x >= 48 && x <= 57 }

    private func number(_ inp: Input) throws -> Token {
        let b = inp.src.text
        var p = inp.pos
        let tok: Token
        if b[p] == 48 && p + 1 < b.count && (b[p + 1] == 120 || b[p + 1] == 88) { // 0x 0X
            p += 2
            var v: Int64 = 0
            while p < b.count {
                let d = hexDigit(Int(b[p]))
                if d < 0 { break }
                v = (v &<< 4) | Int64(d); p += 1
            }
            tok = Token(.INT, "", inp.src.name, inp.line); tok.ival = v
        } else if b[p] == 48 && p + 1 < b.count && (b[p + 1] == 98 || b[p + 1] == 66) { // 0b 0B
            p += 2
            var v: Int64 = 0
            while p < b.count && (b[p] == 48 || b[p] == 49) {
                v = (v &<< 1) | Int64(b[p] - 48); p += 1
            }
            tok = Token(.INT, "", inp.src.name, inp.line); tok.ival = v
        } else {
            let s = p
            while p < b.count && isDigit(b[p]) { p += 1 }
            var isFloat = false
            if p < b.count && Int(b[p]) == cDOT && !(p + 1 < b.count && Int(b[p + 1]) == cDOT) {
                isFloat = true; p += 1
                while p < b.count && isDigit(b[p]) { p += 1 }
            }
            if p < b.count && (b[p] == 101 || b[p] == 69) { // e E
                var q = p + 1
                if q < b.count && (b[q] == 45 || b[q] == 43) { q += 1 }
                if q < b.count && isDigit(b[q]) {
                    isFloat = true
                    p = q
                    while p < b.count && isDigit(b[p]) { p += 1 }
                }
            }
            let str = latin1(b, s, p - s)
            if isFloat {
                tok = Token(.FLOAT, str, inp.src.name, inp.line); tok.fval = Lexer.parseDouble(str)
            } else {
                tok = Token(.INT, str, inp.src.name, inp.line)
                // Kotlin parseUnsignedLong throws NumberFormatException on overflow.
                guard let u = UInt64(str.isEmpty ? "0" : str) else {
                    throw CompileError("integer constant too large: \(str)", inp.src.name, inp.line)
                }
                tok.ival = Int64(bitPattern: u)
            }
        }
        inp.pos = p
        return tok
    }

    /** Java Double.parseDouble for the digit/./exponent strings produced by number(). */
    private static func parseDouble(_ s: String) -> Double {
        if let v = Double(s) { return v }
        // Swift rejects some forms Java accepts (e.g. "1." / exponent overflow); fall back to strtod.
        return s.withCString { strtod($0, nil) }
    }

    /** Reads an escape after a backslash at b[p]; returns (byte, newPos). */
    private func escape(_ b: [UInt8], _ p0: Int) -> (Int, Int) {
        var p = p0
        let c = Int(b[p])
        p += 1
        switch c {
        case 110: return (10, p)  // n
        case 116: return (9, p)   // t
        case 114: return (13, p)  // r
        case c0...c7:
            var v = c - c0
            var n = 1
            while n < 3 && p < b.count && Int(b[p]) >= c0 && Int(b[p]) <= c7 {
                v = v * 8 + (Int(b[p]) - c0); p += 1; n += 1
            }
            return (v & 0xFF, p)
        case 120, 88: // x X
            var v = 0
            var n = 0
            while n < 2 && p < b.count && hexDigit(Int(b[p])) >= 0 {
                v = v * 16 + hexDigit(Int(b[p])); p += 1; n += 1
            }
            return (v, p)
        case 97: return (7, p)    // a
        case 98: return (8, p)    // b
        case 102: return (12, p)  // f
        case 118: return (11, p)  // v
        case 101: return (27, p)  // e
        case 100: return (cDOLLAR, p) // d
        default: return (c, p)
        }
    }

    /** Appends literal content handling escapes and DolDoc ($$ -> $, $..$ kept). */
    private func literal(_ inp: Input, _ quote: Int) throws -> [UInt8] {
        let b = inp.src.text
        var p = inp.pos + 1
        var res: [UInt8] = []
        while true {
            if p >= b.count { throw CompileError("unterminated literal", inp.src.name, inp.line) }
            let c = Int(b[p])
            if c == quote { p += 1; break }
            if c == cNL { inp.line += 1 }
            if c == cBSLASH && p + 1 < b.count {
                let (v, np) = escape(b, p + 1)
                res.append(UInt8(truncatingIfNeeded: v)); p = np; continue
            }
            if c == cDOLLAR {
                if p + 1 < b.count && Int(b[p + 1]) == cDOLLAR { res.append(UInt8(cDOLLAR)); p += 2; continue }
                let end = dollarEnd(b, p)
                if end > p { res.append(contentsOf: b[p...end]); p = end + 1; continue }
            }
            res.append(UInt8(c)); p += 1
        }
        inp.pos = p
        return res
    }

    private func string(_ inp: Input) throws -> Token {
        let line = inp.line
        let bytes = try literal(inp, cQUOTE)
        let t = Token(.STR, "", inp.src.name, line); t.bytes = bytes
        return t
    }

    private func charLit(_ inp: Input) throws -> Token {
        let line = inp.line
        let bytes = try literal(inp, cAPOS)
        if bytes.count > 8 { throw CompileError("char constant longer than 8 chars", inp.src.name, line) }
        var v: Int64 = 0
        for i in bytes.indices.reversed() { v = (v &<< 8) | Int64(bytes[i]) }
        let t = Token(.CHAR, "", inp.src.name, line); t.ival = v; t.charLen = bytes.count
        return t
    }

    private func punct(_ inp: Input) throws -> Token {
        let b = inp.src.text
        for len in stride(from: 3, through: 1, by: -1) {
            if inp.pos + len > b.count { continue }
            let s = latin1(b, inp.pos, len)
            if Lexer.PUNCTS.contains(s) {
                inp.pos += len
                return Token(.PUNCT, s, inp.src.name, inp.line)
            }
        }
        let ch = Int(b[inp.pos])
        throw CompileError("unexpected character '\(latin1([UInt8(ch)]))' (0x\(String(ch, radix: 16)))", inp.src.name, inp.line)
    }

    public static let PUNCTS: Set<String> = [
        "<<=", ">>=", "...",
        "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "^^",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::",
        "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<", ">", "=", "(", ")",
        "[", "]", "{", "}", ",", ";", ":", ".", "?", "`", "#", "@", "\\",
    ]

    public static func resolvePath(_ dir: String, _ path: String) -> String {
        // Work on unicode scalars: Kotlin strings index UTF-16 units (Latin-1 here),
        // and Swift Characters would merge "\r\n".
        var p: [Unicode.Scalar] = path.unicodeScalars.map { $0 == "\\" ? "/" : $0 }
        func str(_ a: ArraySlice<Unicode.Scalar>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: a); return String(v) }
        func starts(_ pre: String) -> Bool { p.starts(with: pre.unicodeScalars) }
        if starts("::/") {
            p = Array(("C:" + str(p[2...])).unicodeScalars)
        } else if p.count >= 2 && p[1] == ":" {
            p = Array((str(p[0..<1]).uppercased() + str(p[1...])).unicodeScalars)
        } else if starts("~/") {
            p = Array(("C:/Home" + str(p[1...])).unicodeScalars)
        } else if starts("/") {
            p = Array(("C:" + str(p[...])).unicodeScalars)
        } else {
            p = Array((dir + "/" + str(p[...])).unicodeScalars)
        }
        var parts: [String] = []
        // Kotlin p.substring(0, 2) throws when p is shorter; clamp instead.
        let dl = min(2, p.count)
        let drive = str(p[0..<dl])
        for seg in str(p[dl...]).unicodeScalars.split(separator: "/", omittingEmptySubsequences: false) {
            let s = String(seg)
            switch s {
            case "", ".": break
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(s)
            }
        }
        return drive + "/" + parts.joined(separator: "/")
    }
}

/** Kotlin anonymous `object : TokenSource` returned by Lexer.stream. */
private final class LexerTokenSource: TokenSource {
    private let lx: Lexer
    init(_ lx: Lexer) { self.lx = lx }
    subscript(i: Int) -> Token {
        get throws {
            while i >= lx.out.count && !lx.eof { try lx.pull() }
            return i < lx.out.count ? lx.out[i] : lx.out[lx.out.count - 1]
        }
    }
    var size: Int { lx.eof ? lx.out.count : Int.max }
}

/** Raised where Kotlin ConstEval would throw (index out of range, division by zero). */
private struct ConstEvalError: Error {}

/** Minimal constant-expression evaluator for `#if`. */
private final class ConstEval {
    let t: [Token]
    var i = 0
    init(_ t: [Token]) { self.t = t }
    func eval() throws -> Int64 { try or() }
    private func peek() -> String { i < t.count ? t[i].text : "" }
    private func next() throws -> Token {
        if i >= t.count { throw ConstEvalError() }
        let tk = t[i]; i += 1
        return tk
    }
    private func or() throws -> Int64 {
        try checkStack() // deeply nested #if expressions
        var v = try and()
        while peek() == "||" { i += 1; let r = try and(); v = (v != 0 || r != 0) ? 1 : 0 }
        return v
    }
    private func and() throws -> Int64 {
        var v = try cmp()
        while peek() == "&&" { i += 1; let r = try cmp(); v = (v != 0 && r != 0) ? 1 : 0 }
        return v
    }
    private static let cmpOps: Set<String> = ["==", "!=", "<", ">", "<=", ">="]
    private func cmp() throws -> Int64 {
        var v = try add()
        while ConstEval.cmpOps.contains(peek()) {
            let op = try next().text; let r = try add()
            let b: Bool
            switch op { case "==": b = v == r; case "!=": b = v != r; case "<": b = v < r; case ">": b = v > r; case "<=": b = v <= r; default: b = v >= r }
            v = b ? 1 : 0
        }
        return v
    }
    private func add() throws -> Int64 {
        var v = try mul()
        while peek() == "+" || peek() == "-" || peek() == "|" || peek() == "&" {
            let op = try next().text; let r = try mul()
            switch op { case "+": v = v &+ r; case "-": v = v &- r; case "|": v = v | r; default: v = v & r }
        }
        return v
    }
    private func mul() throws -> Int64 {
        var v = try un()
        while peek() == "*" || peek() == "/" || peek() == "<<" || peek() == ">>" {
            let op = try next().text; let r = try un()
            switch op {
            case "*": v = v &* r
            case "/": if r == 0 { throw ConstEvalError() }; v = sdiv(v, r)
            case "<<": v = v &<< Int64(Int32(truncatingIfNeeded: r))
            default: v = v &>> Int64(Int32(truncatingIfNeeded: r))
            }
        }
        return v
    }
    private func un() throws -> Int64 {
        let tk = try next()
        if tk.text == "!" { return try un() == 0 ? 1 : 0 }
        if tk.text == "-" { return 0 &- (try un()) }
        if tk.text == "(" { let v = try or(); i += 1; return v }
        if tk.kind == .INT || tk.kind == .CHAR { return tk.ival }
        if tk.text == "TRUE" { return 1 }
        if tk.text == "FALSE" { return 0 }
        return 0
    }
}
