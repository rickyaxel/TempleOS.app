import Foundation

// Port of ui/Json.kt.

public struct JsonError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/**
 * Minimal JSON reader for bundled manifests (objects, arrays, strings, numbers, booleans, null).
 * Objects are `[String: Any?]`, arrays `[Any?]`, numbers `Int64` or `Double`, null is `nil`.
 * Malformed input throws (Kotlin threw IllegalStateException / IndexOutOfBounds).
 */
public enum Json {
    public static func parse(_ s: String) throws -> Any? {
        let r = Reader(s)
        let v = try r.value(); r.ws()
        return v
    }

    private final class Reader {
        let s: [UInt16]
        var i = 0
        init(_ s: String) { self.s = Array(s.utf16) }

        /** s[i] with Kotlin's index check (throws instead of trapping). */
        func at(_ k: Int) throws -> UInt16 {
            if k < 0 || k >= s.count { throw JsonError("index \(k) out of bounds for length \(s.count)") }
            return s[k]
        }

        static func isWhitespace(_ c: UInt16) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return u.properties.isWhitespace || (c >= 0x1C && c <= 0x1F)
        }

        func ws() { while i < s.count && Reader.isWhitespace(s[i]) { i += 1 } }

        /** Nesting depth (the reader is recursive): corrupt input fails cleanly instead of overflowing the stack. */
        var depth = 0
        func nested(_ f: () throws -> Any?) throws -> Any? {
            depth += 1
            defer { depth -= 1 }
            if depth > 512 { throw JsonError("JSON nested too deeply") }
            return try f()
        }
        func value() throws -> Any? {
            ws()
            if i >= s.count { throw JsonError("unexpected end of JSON") }
            switch s[i] {
            case 0x7B: return try nested { try obj() } // {
            case 0x5B: return try nested { try arr() } // [
            case 0x22: return try str() // "
            case 0x74: i += 4; return true // t
            case 0x66: i += 5; return false // f
            case 0x6E: i += 4; return nil // n
            default: return try num()
            }
        }

        func obj() throws -> [String: Any?] {
            var m: [String: Any?] = [:]
            i += 1; ws()
            if try at(i) == 0x7D { i += 1; return m }
            while true {
                ws(); let k = try str(); ws()
                let c = try at(i); i += 1
                if c != 0x3A { throw JsonError("expected ':' at \(i)") }
                m[k] = .some(try value()); ws()
                let d = try at(i); i += 1
                switch d {
                case 0x2C: continue
                case 0x7D: return m
                default: throw JsonError("expected ',' or '}' at \(i)")
                }
            }
        }

        func arr() throws -> [Any?] {
            var l: [Any?] = []
            i += 1; ws()
            if try at(i) == 0x5D { i += 1; return l }
            while true {
                l.append(try value()); ws()
                let d = try at(i); i += 1
                switch d {
                case 0x2C: continue
                case 0x5D: return l
                default: throw JsonError("expected ',' or ']' at \(i)")
                }
            }
        }

        func str() throws -> String {
            if try at(i) != 0x22 { throw JsonError("expected string at \(i)") }
            i += 1
            var sb: [UInt16] = []
            while try at(i) != 0x22 {
                let c = s[i]; i += 1
                if c == 0x5C {
                    let e = try at(i); i += 1
                    switch e {
                    case 0x6E: sb.append(10)   // n
                    case 0x74: sb.append(9)    // t
                    case 0x72: sb.append(13)   // r
                    case 0x62: sb.append(8)    // b
                    case 0x66: sb.append(12)   // f
                    case 0x75:                 // u
                        if i + 4 > s.count { throw JsonError("bad \\u escape") }
                        guard let v = UInt16(String(decoding: s[i..<(i + 4)], as: UTF16.self), radix: 16) else {
                            throw JsonError("bad \\u escape")
                        }
                        sb.append(v); i += 4
                    default: sb.append(e)
                    }
                } else { sb.append(c) }
            }
            i += 1
            return String(decoding: sb, as: UTF16.self)
        }

        func num() throws -> Any {
            let st = i
            while i < s.count && (Reader.isDigit(s[i]) || [0x2B, 0x2D, 0x2E, 0x65, 0x45].contains(s[i])) { i += 1 }
            let t = String(decoding: s[st..<i], as: UTF16.self)
            if t.contains(".") || t.contains("e") || t.contains("E") {
                guard let d = Double(t) else { throw JsonError("bad number '\(t)'") }
                return d
            }
            guard let l = Int64(t) else { throw JsonError("bad number '\(t)'") }
            return l
        }

        static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    }
}
