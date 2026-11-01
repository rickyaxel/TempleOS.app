import Foundation

// Port of core/dynexpr/DynLexer.kt.

public enum DTok { case IDENT, INT, FLOAT, STR, CHAR, PUNCT, BIN, EOF }

public final class DToken: CustomStringConvertible {
    public let kind: DTok
    public let text: String
    public let line: Int
    public var ival: Int64 = 0
    public var fval: Double = 0
    public var bytes: [UInt8]?
    public var charLen = 0
    /** Macro names that must not expand again in this token (the compiler's hide set). */
    public var hidden: Set<String>?

    init(_ kind: DTok, _ text: String, _ line: Int) { self.kind = kind; self.text = text; self.line = line }

    /** As the compiler prints a token in its messages (Token.toString). */
    public var description: String {
        switch kind {
        case .STR: return "\"" + latin1(bytes!) + "\""
        case .INT: return String(ival)
        case .EOF: return "end of file"
        default: return text
        }
    }
}

/**
 * The engine's tokenizer: the rules of the app's HolyC lexer (HolyC/Lexer.swift) for what an expression
 * can contain, with the same error messages. Macros are an allow-list (DynMacros) and every directive is
 * reported (none is executed). Tokens are produced lazily, as the parser asks for them.
 */
public final class DynLexer {
    private let b: [UInt8]
    private let bins: [Int: [UInt8]]
    private let file: String
    private var pos = 0
    private var line: Int
    private var out: [DToken] = []
    private var eof = false
    /** Tokens produced so far (bounded by DynLimits.MAX_TOKENS). */
    public var produced: Int { out.count }

    init(_ text: [UInt8], _ bins: [Int: [UInt8]], _ file: String, _ firstLine: Int = 1) {
        b = text; self.bins = bins; self.file = file; line = firstLine
    }

    func get(_ i: Int) throws -> DToken {
        while i >= out.count && !eof { try pull() }
        return i < out.count ? out[i] : out[out.count - 1]
    }

    /** Lazily: Int.max until the end has been lexed (as the compiler's TokenSource). */
    var size: Int { eof ? out.count : Int.max }

    private func err(_ msg: String, _ ln: Int) -> CompileError { CompileError(msg, file, ln) }

    private func pull() throws {
        let before = out.count
        while out.count == before {
            guard let t = try lexOne() else {
                out.append(DToken(.EOF, "", 0))
                eof = true
                return
            }
            try handle(t)
        }
    }

    private func emit(_ t: DToken) throws {
        if out.count >= DynLimits.MAX_TOKENS { throw DynExpr.limit("longer than \(DynLimits.MAX_TOKENS) tokens", file, t.line) }
        out.append(t)
    }

    private func handle(_ t: DToken) throws {
        if t.kind == .PUNCT && t.text == "#" { try directive(t); return }
        if t.kind == .IDENT {
            switch t.text {
            case "__DIR__", "__FILE__":
                let v: String
                if t.text == "__FILE__" { v = file } else if let i = file.lastIndex(of: "/") { v = String(file[..<i]) } else { v = "C:/" }
                let s = DToken(.STR, "", t.line); s.bytes = latin1(v)
                try emit(s); return
            case "__LINE__":
                let s = DToken(.INT, "", t.line); s.ival = Int64(t.line)
                try emit(s); return
            default: break
            }
            try expand(t, [], 0)
            return
        }
        try emit(t)
    }

    private func expand(_ t: DToken, _ hide: Set<String>, _ depth: Int) throws {
        guard let body = DynMacros.body(t.text), !hide.contains(t.text), !(t.hidden?.contains(t.text) ?? false), depth <= 16 else { try emit(t); return }
        var h = hide; h.insert(t.text); if let th = t.hidden { h.formUnion(th) }
        for x in body {
            let c = DToken(x.kind, x.text, t.line)
            c.ival = x.ival; c.fval = x.fval; c.bytes = x.bytes; c.charLen = x.charLen
            if c.kind == .IDENT { try expand(c, h, depth + 1) } else { try emit(c) }
        }
    }

    /** `#...`: no directive is executed; the compiler's errors are kept for those it rejects too. */
    private func directive(_ hash: DToken) throws {
        skipSpaces(stopAtNewline: true)
        guard let nameTok = try lexOne() else { throw err("bad directive", hash.line) }
        let name = nameTok.text
        switch name {
        case "else": throw err("#else without #if", hash.line)
        case "endif": throw err("#endif without #if", hash.line)
        case "exe": throw err("#exe {} (compile-time code execution) is not supported by \(Brand.appName)", hash.line)
        case "ifdef", "ifndef", "if", "ifjit", "ifaot", "define", "undef", "include", "help_index", "help_file", "assert", "pragma":
            throw DynExpr.outside("the preprocessor directive #\(name)", file, hash.line)
        default: throw err("unknown directive #\(name)", hash.line)
        }
    }

    // ---------------------------------------------------------------- raw lexing (HolyC/Lexer.swift)

    private static func code(_ c: Character) -> UInt8 { UInt8(c.unicodeScalars.first!.value) }
    private static let NL: UInt8 = 10, SP: UInt8 = 32, TAB: UInt8 = 9, CR: UInt8 = 13, SLASH: UInt8 = 47, STAR: UInt8 = 42
    private static let DOLLAR: UInt8 = 36, QUOTE: UInt8 = 34, APOS: UInt8 = 39, BSLASH: UInt8 = 92, DOT: UInt8 = 46

    private func skipSpaces(stopAtNewline: Bool) {
        while pos < b.count {
            let c = b[pos]
            if c == DynLexer.NL {
                if stopAtNewline { return }
                line += 1; pos += 1
            } else if c == DynLexer.SP || c == DynLexer.TAB || c == DynLexer.CR || c == 0x0C || c == 5 {
                pos += 1
            } else if c == DynLexer.SLASH && pos + 1 < b.count && b[pos + 1] == DynLexer.SLASH {
                while pos < b.count && b[pos] != DynLexer.NL { pos += 1 }
            } else if c == DynLexer.SLASH && pos + 1 < b.count && b[pos + 1] == DynLexer.STAR {
                pos += 2
                var depth = 1
                while pos < b.count && depth > 0 {
                    let d = b[pos]
                    if d == DynLexer.NL { line += 1 }
                    if d == DynLexer.STAR && pos + 1 < b.count && b[pos + 1] == DynLexer.SLASH { depth -= 1; pos += 2; continue }
                    if d == DynLexer.SLASH && pos + 1 < b.count && b[pos + 1] == DynLexer.STAR { depth += 1; pos += 2; continue }
                    pos += 1
                }
            } else if c == DynLexer.DOLLAR {
                let end = dollarEnd(pos)
                if end < 0 { pos += 1; continue }
                if end == pos + 1 { pos += 2; continue }
                let code = String(latin1(b, pos + 1, end - pos - 1).prefix(2))
                if code == "IB" || code == "IS" || code == "TX" { return }
                pos = end + 1
            } else {
                return
            }
        }
    }

    private func dollarEnd(_ p: Int) -> Int {
        var i = p + 1
        var inQ = false
        while i < b.count {
            let c = b[i]
            if c == DynLexer.NL { return -1 }
            if c == DynLexer.QUOTE { inQ = !inQ }
            else if c == DynLexer.BSLASH && inQ { i += 1 }
            else if c == DynLexer.DOLLAR && !inQ { return i }
            i += 1
        }
        return -1
    }

    func lexOne() throws -> DToken? {
        skipSpaces(stopAtNewline: false)
        if pos >= b.count { return nil }
        let start = pos
        let c = Int(b[start])
        if c == 36 { return try dollarToken() }
        if isIdStart(c) {
            var p = start + 1
            var seg = start
            var name = ""
            while true {
                while p < b.count && isIdChar(Int(b[p])) { p += 1 }
                if p < b.count && b[p] == DynLexer.DOLLAR {
                    let end = dollarEnd(p)
                    if end > p + 1 && end + 1 < b.count && isIdChar(Int(b[end + 1])) {
                        let code = latin1(b, p + 1, min(2, end - p - 1))
                        if code != "IB" && code != "IS" && code != "TX" {
                            name += latin1(b, seg, p - seg); p = end + 1; seg = p; continue
                        }
                    }
                }
                break
            }
            name += latin1(b, seg, p - seg)
            pos = p
            return DToken(.IDENT, name, line)
        }
        if (48...57).contains(c) || (c == 46 && start + 1 < b.count && (48...57).contains(Int(b[start + 1]))) { return try number() }
        if c == 34 {
            let ln = line
            let bytes = try literal(34)
            let t = DToken(.STR, "", ln); t.bytes = bytes
            return t
        }
        if c == 39 { return try charLit() }
        return try punct()
    }

    /** "BI=<digits>" anywhere in a DolDoc command (Regex("BI=(\\d+)").find). */
    private static func binIndex(_ cmd: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < cmd.count + 1 {
            if i + 3 <= cmd.count && cmd[i] == 66 && cmd[i + 1] == 73 && cmd[i + 2] == 61 {
                var j = i + 3, v = 0, n = 0
                while j < cmd.count && cmd[j] >= 48 && cmd[j] <= 57 { v = v &* 10 &+ Int(cmd[j] - 48); j += 1; n += 1 }
                if n > 0 { return n > 9 ? nil : v }
            }
            i += 1
        }
        return nil
    }

    /** The quoted text of a $TX$ command (Regex("^TX[^\"]*\"((?:[^\"\\\\]|\\\\.)*)\"")), or "". */
    private static func txText(_ cmd: [UInt8]) -> [UInt8] {
        guard cmd.count >= 2 && cmd[0] == 84 && cmd[1] == 88 else { return [] }
        var i = 2
        while i < cmd.count && cmd[i] != 34 { i += 1 }
        if i >= cmd.count { return [] }
        i += 1
        let s = i
        while i < cmd.count {
            if cmd[i] == 34 { return Array(cmd[s..<i]) }
            if cmd[i] == 92 { if i + 1 >= cmd.count { return [] }; i += 2; continue }
            i += 1
        }
        return []
    }

    private func dollarToken() throws -> DToken {
        let end = dollarEnd(pos)
        let cmd = Array(b[(pos + 1)..<end])
        pos = end + 1
        let code = String(latin1(cmd).prefix(2))
        let bi = DynLexer.binIndex(cmd)
        switch code {
        case "IB":
            guard let i = bi, let data = bins[i] else { throw err("missing binary attachment in $\(latin1(cmd))$", line) }
            let t = DToken(.BIN, "<bin>", line); t.bytes = data
            return t
        case "IS":
            let t = DToken(.INT, "", line); t.ival = Int64(bi.flatMap { bins[$0] }?.count ?? 0)
            return t
        default:
            let sub = DynLexer(DynLexer.txText(cmd), [:], file, line)
            return try sub.lexOne() ?? DToken(.PUNCT, ";", line)
        }
    }

    private func isIdStart(_ c: Int) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 || c >= 128 }
    private func isIdChar(_ c: Int) -> Bool { isIdStart(c) || (48...57).contains(c) }
    private func hexDigit(_ c: Int) -> Int {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 97 + 10
        case 65...70: return c - 65 + 10
        default: return -1
        }
    }
    private func isDigit(_ x: UInt8) -> Bool { x >= 48 && x <= 57 }

    /** Lexer.parseDouble: Swift's Double(String), with strtod for the forms Java accepts and Swift does not. */
    static func parseDouble(_ s: String) -> Double {
        if let v = Double(s) { return v }
        return s.withCString { strtod($0, nil) }
    }

    private func number() throws -> DToken {
        var p = pos
        let tok: DToken
        if b[p] == 48 && p + 1 < b.count && (b[p + 1] == 120 || b[p + 1] == 88) {
            p += 2
            var v: Int64 = 0
            while p < b.count {
                let d = hexDigit(Int(b[p]))
                if d < 0 { break }
                v = (v &<< 4) | Int64(d); p += 1
            }
            tok = DToken(.INT, "", line); tok.ival = v
        } else if b[p] == 48 && p + 1 < b.count && (b[p + 1] == 98 || b[p + 1] == 66) {
            p += 2
            var v: Int64 = 0
            while p < b.count && (b[p] == 48 || b[p] == 49) { v = (v &<< 1) | Int64(b[p] - 48); p += 1 }
            tok = DToken(.INT, "", line); tok.ival = v
        } else {
            let s = p
            while p < b.count && isDigit(b[p]) { p += 1 }
            var isFloat = false
            if p < b.count && b[p] == DynLexer.DOT && !(p + 1 < b.count && b[p + 1] == DynLexer.DOT) {
                isFloat = true; p += 1
                while p < b.count && isDigit(b[p]) { p += 1 }
            }
            if p < b.count && (b[p] == 101 || b[p] == 69) {
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
                tok = DToken(.FLOAT, str, line); tok.fval = DynLexer.parseDouble(str)
            } else {
                tok = DToken(.INT, str, line)
                guard let u = UInt64(str.isEmpty ? "0" : str) else { throw err("integer constant too large: \(str)", line) }
                tok.ival = Int64(bitPattern: u)
            }
        }
        pos = p
        return tok
    }

    /** An escape after a backslash at [p0]: (byte, next position). */
    private func escape(_ p0: Int) -> (Int, Int) {
        var p = p0
        let c = Int(b[p])
        p += 1
        switch c {
        case 110: return (10, p)
        case 116: return (9, p)
        case 114: return (13, p)
        case 48...55:
            var v = c - 48
            var n = 1
            while n < 3 && p < b.count && (48...55).contains(Int(b[p])) { v = v * 8 + Int(b[p] - 48); p += 1; n += 1 }
            return (v & 0xFF, p)
        case 120, 88:
            var v = 0, n = 0
            while n < 2 && p < b.count && hexDigit(Int(b[p])) >= 0 { v = v * 16 + hexDigit(Int(b[p])); p += 1; n += 1 }
            return (v, p)
        case 97: return (7, p)
        case 98: return (8, p)
        case 102: return (12, p)
        case 118: return (11, p)
        case 101: return (27, p)
        case 100: return (36, p)
        default: return (c, p)
        }
    }

    private func literal(_ quote: Int) throws -> [UInt8] {
        var p = pos + 1
        var res: [UInt8] = []
        while true {
            if p >= b.count { throw err("unterminated literal", line) }
            let c = Int(b[p])
            if c == quote { p += 1; break }
            if c == 10 { line += 1 }
            if c == 92 && p + 1 < b.count {
                let (v, np) = escape(p + 1)
                res.append(UInt8(truncatingIfNeeded: v)); p = np; continue
            }
            if c == 36 {
                if p + 1 < b.count && b[p + 1] == DynLexer.DOLLAR { res.append(36); p += 2; continue }
                let end = dollarEnd(p)
                if end > p { res.append(contentsOf: b[p...end]); p = end + 1; continue }
            }
            res.append(UInt8(c)); p += 1
        }
        pos = p
        return res
    }

    private func charLit() throws -> DToken {
        let ln = line
        let bytes = try literal(39)
        if bytes.count > 8 { throw err("char constant longer than 8 chars", ln) }
        var v: Int64 = 0
        for x in bytes.reversed() { v = (v &<< 8) | Int64(x) }
        let t = DToken(.CHAR, "", ln); t.ival = v; t.charLen = bytes.count
        return t
    }

    private func punct() throws -> DToken {
        for len in stride(from: 3, through: 1, by: -1) {
            if pos + len > b.count { continue }
            let s = latin1(b, pos, len)
            if DynLexer.PUNCTS.contains(s) {
                pos += len
                return DToken(.PUNCT, s, line)
            }
        }
        let ch = Int(b[pos])
        throw err("unexpected character '\(latin1([UInt8(ch)]))' (0x\(String(ch, radix: 16)))", line)
    }

    /** The whole text as tokens without macro expansion (macro bodies). */
    func rawTokens() -> [DToken] {
        var res: [DToken] = []
        while let t = try? lexOne() { res.append(t) }
        return res
    }

    static let PUNCTS: Set<String> = [
        "<<=", ">>=", "...",
        "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "^^",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::",
        "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<", ">", "=", "(", ")",
        "[", "]", "{", "}", ",", ";", ":", ".", "?", "`", "#", "@", "\\",
    ]
}

/**
 * The TempleOS constants an expression may use: the numeric `#define`s of Kernel/KernelA.HH as shipped in
 * shared/runtime/PreludeDefines.HC, bodies verbatim (DynExprUnitTests checks them against the interpreter).
 */
public enum DynMacros {
    /** name -> body text, in the Kotlin table's order (\u{EC} and \u{E3} are CP437's infinity and pi signs). */
    public static let TEXT: [(String, String)] = [
        ("NULL", "0"), ("TRUE", "1"), ("FALSE", "0"), ("ON", "1"), ("OFF", "0"),
        ("I8_MIN", "(-0x80)"), ("I8_MAX", "0x7F"), ("U8_MIN", "0"), ("U8_MAX", "0xFF"),
        ("I16_MIN", "(-0x8000)"), ("I16_MAX", "0x7FFF"), ("U16_MIN", "0"), ("U16_MAX", "0xFFFF"),
        ("I32_MIN", "(-0x80000000)"), ("I32_MAX", "0x7FFFFFFF"), ("U32_MIN", "0"), ("U32_MAX", "0xFFFFFFFF"),
        ("I64_MIN", "(-0x8000000000000000)"), ("I64_MAX", "0x7FFFFFFFFFFFFFFF"), ("U64_MIN", "0"), ("U64_MAX", "0xFFFFFFFFFFFFFFFF"),
        ("U64_F64_MAX", "(0x43F0000000000000(F64))"), ("F64_MAX", "(0x7FEFFFFFFFFFFFFF(F64))"), ("F64_MIN", "(0xFFEFFFFFFFFFFFFF(F64))"),
        ("inf", "(0x7FF0000000000000(F64))"), ("\u{EC}", "(0x7FF0000000000000(F64))"),
        ("pi", "(0x400921FB54442D18(F64))"), ("\u{E3}", "(0x400921FB54442D18(F64))"),
        ("exp_1", "(0x4005BF0A8B145769(F64))"), ("log2_10", "(0x400A934F0979A371(F64))"), ("log2_e", "(0x3FF71547652B82FE(F64))"),
        ("log10_2", "(0x3FD34413509F79FF(F64))"), ("loge_2", "(0x3FE62E42FEFA39EF(F64))"), ("sqrt2", "(0x3FF6A09E667F3BCD(F64))"),
        ("eps", "(0x3CB0000000000000(F64))"),
    ]

    private static let bodies: [String: [DToken]] = {
        var m: [String: [DToken]] = [:]
        for (name, text) in TEXT { m[name] = DynLexer(latin1(text), [:], "macro").rawTokens() }
        return m
    }()

    public static func body(_ name: String) -> [DToken]? { bodies[name] }

    private static let lock = NSLock()
    private static var known: Set<String>?

    /** True when a TempleOS header `#define`s [name] (names read once from the runtime files). */
    public static func isKnownMacro(_ name: String, _ runtimeFile: (String) -> [UInt8]?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if known == nil {
            var set = Set<String>()
            let prefix = latin1("#define ")
            for f in ["PreludeDefines.HC", "Prelude.HC", "GrLib.HC"] {
                guard let text = runtimeFile(f) else { continue }
                var i = 0
                while i < text.count {
                    var e = i
                    while e < text.count && text[e] != 10 { e += 1 }
                    var s = i
                    while s < e && (text[s] == 32 || text[s] == 9) { s += 1 }
                    if e - s > 8 && Array(text[s..<(s + 8)]) == prefix {
                        var n = s + 8
                        while n < e && text[n] == 32 { n += 1 }
                        var ne = n
                        while ne < e && text[ne] != 32 && text[ne] != 9 && text[ne] != 13 { ne += 1 }
                        if ne > n { set.insert(latin1(text, n, ne - n)) }
                    }
                    i = e + 1
                }
            }
            known = set
        }
        return known!.contains(name)
    }
}
