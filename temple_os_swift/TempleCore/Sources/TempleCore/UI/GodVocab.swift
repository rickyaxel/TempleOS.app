import Compression
import CryptoKit
import Foundation

// Port of ui/GodVocab.kt.

/**
 * Terry Davis' God vocabulary and its translations (docs/localization-vocabulary.md).
 *
 * The English entries are the reference: `tokenize` splits Adam/God/Vocab.DD exactly as GodInit
 * (Adam/God/HolySpirit.HC) does, and entry i keeps index i. GodWordStr picks
 * god.words[GodBits(17) % god.num_words]; translations only change how a picked entry is shown,
 * never which entry is picked or how many there are.
 *
 * Translations are bundled runtime files, one per UI catalog (`l10n/vocab/<catalog>.deflate`,
 * written by tools/l10n/vocab.py): raw DEFLATE of UTF-8 lines, a header
 * `#templeos-vocab 1 count=<n> sha256=<hex>` naming the English vocabulary they translate, then one
 * line per entry ("" = not translated). Only the current catalog is loaded, on first use; a missing,
 * corrupt or mismatched file shows the English entries.
 */
public enum GodVocab {
    public static let FORMAT = "#templeos-vocab 1"

    /** Kernel/StrA.HC char_bmp_word: ' 0-9 A-Z _ a-z and every byte >= 128. */
    @inline(__always) public static func isWordChar(_ b: UInt8) -> Bool {
        b == 0x27 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || b == 0x5F || (b >= 0x61 && b <= 0x7A) || b >= 0x80
    }

    /** GodInit's word list: runs of word characters in the text part (FileRead's string ends at the first NUL). */
    public static func tokenize(_ data: [UInt8]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(8192)
        let n = data.firstIndex(of: 0) ?? data.count
        var i = 0
        while i < n {
            while i < n && !isWordChar(data[i]) { i += 1 }
            if i >= n { break }
            let j = i
            while i < n && isWordChar(data[i]) { i += 1 }
            // one char per byte (Latin-1), then CP437 as TempleOS shows it
            out.append(Cp437.decode(String(bytes: data[j..<i], encoding: .isoLatin1) ?? ""))
        }
        return out
    }

    /** sha256 of the entries joined by '\n' (UTF-8), as in the translation files' header. */
    public static func digest(_ entries: [String]) -> String {
        SHA256.hash(data: Data(entries.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /** Why a catalog shows English entries: "ok" (translations loaded), "english", "missing", "mismatch" or "corrupt". */
    public final class Table {
        public let catalog: String, status: String
        private let lines: [String]?
        init(_ catalog: String, _ status: String, _ lines: [String]?) { self.catalog = catalog; self.status = status; self.lines = lines }
        /** The translation of entry `i`, or nil (shown in English). */
        public func translation(_ i: Int) -> String? {
            guard let l = lines, i >= 0, i < l.count, !l[i].isEmpty else { return nil }
            return l[i]
        }
        public var translated: Int { lines?.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) } ?? 0 }
    }

    private static let lock = NSLock()
    private static var cached: Table? = nil
    private static var cachedDigest = ""
    /** How many translation files were read and decoded (tests: language switches load once). */
    public private(set) static var loads = 0

    /**
     * The translations of the vocabulary with `digest` for `catalog`, from `source` (runtime files).
     * One catalog is kept; asking for another releases it.
     */
    public static func table(_ catalog: String, _ digest: String, _ count: Int, _ source: (String) -> [UInt8]?) -> Table {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.catalog == catalog, cachedDigest == digest { return c }
        let t = catalog == "en" ? Table(catalog, "english", nil) : load(catalog, digest, count, source)
        cached = t; cachedDigest = digest
        return t
    }

    private static func load(_ catalog: String, _ digest: String, _ count: Int, _ source: (String) -> [UInt8]?) -> Table {
        guard let raw = source("l10n/vocab/\(catalog).deflate") else { return Table(catalog, "missing", nil) }
        loads += 1
        guard let bytes = inflate(raw) else { return Table(catalog, "corrupt", nil) }
        // invalid UTF-8 becomes U+FFFD, as Kotlin's decoder does; such entries are rejected below
        var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let head = lines.first, head.hasPrefix(FORMAT) else { return Table(catalog, "corrupt", nil) }
        // the file must translate this exact vocabulary (a user copy of Vocab.DD has other entries)
        if head != "\(FORMAT) count=\(count) sha256=\(digest)" { return Table(catalog, "mismatch", nil) }
        if lines.count != count + 1 { return Table(catalog, "corrupt", nil) }
        return Table(catalog, "ok", (0..<count).map { valid(lines[$0 + 1]) ? lines[$0 + 1] : "" })
    }

    /** No control characters or U+FFFD (a decoding error); such an entry is shown in English. */
    private static func valid(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0xFFFD } }

    /** Raw DEFLATE (RFC 1951; Apple's COMPRESSION_ZLIB) of unknown size, or nil if the data is not valid. */
    static func inflate(_ src: [UInt8]) -> [UInt8]? {
        if src.isEmpty { return nil }
        var cap = max(4096, src.count * 8)
        while cap <= 1 << 28 {
            var dst = [UInt8](repeating: 0, count: cap)
            let n = src.withUnsafeBufferPointer { s in
                dst.withUnsafeMutableBufferPointer { d in
                    compression_decode_buffer(d.baseAddress!, cap, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n == 0 { return nil }
            if n < cap { return Array(dst[0..<n]) }
            cap *= 4 // the output filled the buffer: it may be longer
        }
        return nil
    }
}

/**
 * The vocabulary God Words picks from: the English entries of a Vocab.DD file and their display in
 * the current UI language.
 */
public final class Vocabulary {
    public let entries: [String]
    public let digest: String
    private let source: (String) -> [UInt8]?
    public init(_ entries: [String], _ source: @escaping (String) -> [UInt8]?) {
        self.entries = entries; self.source = source; digest = GodVocab.digest(entries)
    }
    public var size: Int { entries.count }

    /** Entry `i` in the current UI language (the English entry when there is no translation). */
    public func display(_ i: Int) -> String { table().translation(i) ?? entries[i] }

    /** The current catalog's translations. */
    public func table() -> GodVocab.Table { GodVocab.table(L10n.locale?.catalog ?? "en", digest, entries.count, source) }
}
