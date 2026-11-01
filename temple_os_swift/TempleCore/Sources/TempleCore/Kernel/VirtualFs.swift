import Foundation

// Port of kernel/VirtualFs.kt.

/** A directory entry of the virtual TempleOS filesystem. */
public struct FsEntry: Equatable {
    public let name: String
    public let path: String
    public let isDir: Bool
    public let size: Int64
    public let modified: Int64
    public let readOnly: Bool
    public init(_ name: String, _ path: String, _ isDir: Bool, _ size: Int64, _ modified: Int64, _ readOnly: Bool) {
        self.name = name; self.path = path; self.isDir = isDir; self.size = size; self.modified = modified; self.readOnly = readOnly
    }
}

/**
 * A filesystem error. [message] is English (HolyC programs and the TempleOS console show it);
 * the UI shows [key] translated with [args] (`ui.localized()`).
 */
public struct FsError: Error, CustomStringConvertible {
    public let message: String
    public let key: String?
    public let args: [String: Any?]
    public init(_ message: String, _ key: String? = nil, _ args: [String: Any?] = [:]) { self.message = message; self.key = key; self.args = args }
    public var description: String { message }
}

/**
 * The logical TempleOS filesystem (C:/...). Implementations map logical paths to
 * an immutable bundled layer plus a writable overlay inside the app sandbox.
 * All paths are absolute logical paths such as "C:/Home/Hello.HC".
 */
public protocol VirtualFs: AnyObject {
    func readFile(_ path: String) -> [UInt8]?
    /** Atomically writes a file. Throws [FsError] (read-only, quota, invalid path). */
    func writeFile(_ path: String, _ data: [UInt8]) throws
    func exists(_ path: String) -> Bool
    func isDir(_ path: String) -> Bool
    func list(_ dir: String) -> [FsEntry]?
    func stat(_ path: String) -> FsEntry?
    func mkdir(_ path: String) throws
    /** Deletes a file or an empty directory (or a tree when [recursive]). */
    func delete(_ path: String, recursive: Bool) throws
    func move(_ from: String, _ to: String) throws
    func isReadOnly(_ path: String) -> Bool
}

public extension VirtualFs {
    func delete(_ path: String) throws { try delete(path, recursive: false) }
}

public enum Paths {
    /** Normalizes a TempleOS path relative to [cwd] ("C:/Home"). Returns nil if invalid. */
    public static func normalize(_ cwd: String, _ p0: String) -> String? {
        var p = p0.trimmed().replacingOccurrences(of: "\\", with: "/")
        if p.isEmpty { return cwd }
        let chars = Array(p)
        if p.hasPrefix("::/") { p = "C:" + String(p.dropFirst(2)) }
        else if p == "::" { p = "C:/" }
        else if chars.count >= 2 && chars[1] == ":" { p = String(chars[0]).uppercased() + String(chars[1...]) }
        else if p.hasPrefix("~/") { p = "C:/Home" + String(p.dropFirst(1)) }
        else if p == "~" { p = "C:/Home" }
        else if p.hasPrefix("/") { p = "C:" + p }
        else { p = cwd.trimEnd("/") + "/" + p }
        if !p.hasPrefix("C:") { return nil }
        var parts: [String] = []
        // split on the '/' scalar, not on Characters: "/" + a combining mark is one grapheme
        for seg in String(p.dropFirst(2)).unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map({ String(String.UnicodeScalarView($0)) }) {
            switch seg {
            case "", ".": break
            case "..": if !parts.isEmpty { parts.removeLast() }
            default:
                // RedSea names are bytes: Latin-1 only (also keeps Unicode combining marks out of paths)
                if seg.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 0xFF || ":*?\"<>|".unicodeScalars.contains($0) }) { return nil }
                if seg.utf16.count > 38 { return nil } // RedSea name limit (Kotlin String.length)
                parts.append(seg)
            }
        }
        return "C:/" + parts.joined(separator: "/")
    }

    public static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "C:/" }
        let pos = p.distance(from: p.startIndex, to: i)
        return pos <= 2 ? "C:/" : String(p[..<i])
    }

    public static func name(_ p: String) -> String { p.substringAfterLast("/") }

    /** TempleOS wildcard match ("*.HC", "*", "Hello*"); case-insensitive. */
    public static func matches(_ mask: String, _ name: String) -> Bool {
        let masks = mask.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        if masks.isEmpty { return true }
        let s = Array(name.lowercased().unicodeScalars)
        return masks.contains { m in globMatch(Array(m.lowercased().unicodeScalars), 0, s, 0) }
    }

    private static func globMatch(_ p: [Unicode.Scalar], _ pi: Int, _ s: [Unicode.Scalar], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        switch p[pi] {
        case "*": return (si...s.count).contains { globMatch(p, pi + 1, s, $0) }
        case "?": return si < s.count && globMatch(p, pi + 1, s, si + 1)
        default: return si < s.count && s[si] == p[pi] && globMatch(p, pi + 1, s, si + 1)
        }
    }
}
