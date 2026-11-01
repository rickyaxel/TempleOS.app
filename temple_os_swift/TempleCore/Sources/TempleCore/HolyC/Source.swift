import Foundation

// Port of holyc/Source.kt. `latin1(...)` and `CompileError` live in Basics.swift.

/**
 * A HolyC/DolDoc source file split into its text part and its binary records
 * (sprites etc.). TempleOS stores binaries after a NUL that terminates the text:
 * `U32 num, U32 flags, U32 size, U32 use_cnt, U8 data[size]` repeated.
 */
public final class SourceFile {
    public let name: String
    public let text: [UInt8]
    public let bins: [Int: [UInt8]]

    public init(_ name: String, _ text: [UInt8], _ bins: [Int: [UInt8]]) {
        self.name = name; self.text = text; self.bins = bins
    }

    public static func parse(_ name: String, _ raw: [UInt8]) -> SourceFile {
        guard let end = raw.firstIndex(of: 0) else { return SourceFile(name, raw, [:]) }
        let text = Array(raw[0..<end])
        var bins: [Int: [UInt8]] = [:]
        var p = end + 1
        while p + 16 <= raw.count {
            let num = le32(raw, p)
            let size = le32(raw, p + 8)
            p += 16
            if size < 0 || p + size > raw.count { break }
            bins[num] = Array(raw[p..<(p + size)])
            p += size
        }
        return SourceFile(name, text, bins)
    }

    public static func ofString(_ name: String, _ s: String) -> SourceFile { SourceFile(name, latin1(s), [:]) }

    /** Kotlin Int (32-bit, signed) little-endian read. */
    private static func le32(_ b: [UInt8], _ p: Int) -> Int {
        let u = UInt32(b[p]) | (UInt32(b[p + 1]) << 8) | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24)
        return Int(Int32(bitPattern: u))
    }
}

/** Resolves `#include` paths. Implemented by the virtual filesystem. */
public protocol SourceProvider: AnyObject {
    /** Returns the raw file bytes for an absolute logical path, or nil. */
    func read(_ path: String) -> [UInt8]?
}

/** Kotlin `SourceProvider { path -> ... }` (fun interface lambda). */
public final class ClosureSourceProvider: SourceProvider {
    private let fn: (String) -> [UInt8]?
    public init(_ fn: @escaping (String) -> [UInt8]?) { self.fn = fn }
    public func read(_ path: String) -> [UInt8]? { fn(path) }
}
