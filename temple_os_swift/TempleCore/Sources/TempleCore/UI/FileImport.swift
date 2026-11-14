import Foundation

// Port of ui/FileImport.kt.

/** Why an import was refused: a catalog key (import.error.*) and its placeholders, ready to show. */
public struct ImportError: Error, CustomStringConvertible {
    public let key: String
    public let args: [(String, Any?)]
    public init(_ key: String, _ args: (String, Any?)...) { self.key = key; self.args = args }
    public var description: String { ([key] + args.map { "\($0.0)=\($0.1.map { "\($0)" } ?? "nil")" }).joined(separator: " ") }
}

/**
 * A document the user picked, as the platform hands it over: its own name (Unicode, from the provider) and a
 * private copy in app storage ([hostPath], which the import deletes when done), or why there is none.
 */
public struct PickedFile {
    public let name: String
    public let hostPath: String?
    public let problem: ImportError?
    public init(name: String, hostPath: String?, problem: ImportError? = nil) { self.name = name; self.hostPath = hostPath; self.problem = problem }
}

/**
 * Imports external TempleOS files onto the C: drive (docs/file-import.md): HolyC source (.HC), TempleOS-compressed
 * source (.HC.Z: expanded with Kernel/Compress.HC's algorithm and stored under its name without .Z, as the bundled
 * drive stores the ISO's compressed files) and ZIP archives (extracted with their folders; TempleOS-compressed
 * files inside are expanded the same way). Everything goes to [DESTINATION] in the user's overlay, where Files,
 * the Terminal, the editor and the HolyC interpreter find it like any other file.
 *
 * [prepare] (any thread) reads, checks and decodes one picked file into a hidden staging folder ([LayeredFs.Stage]);
 * nothing is visible until [publish] (UI thread) renames it into place, so a refused or failed import leaves no
 * trace. Input is untrusted: names are checked as RedSea names, archives against the limits below before anything
 * is extracted, and type is decided by name and checked against content (MIME types are never used).
 */
public enum FileImport {
    /** Where imports go: a folder of the user's home (Files and the Terminal start in C:/Home). */
    public static let DESTINATION = "C:/Home/Imports"

    /** A picked .HC or .HC.Z, and any one file from an archive, after expansion. */
    public static let MAX_FILE_BYTES = 16 << 20
    /** A picked .zip. */
    public static let MAX_ARCHIVE_BYTES = 32 << 20
    /** Everything one archive extracts to (the drive's quota, 64 MiB for all the user's files, also applies). */
    public static let MAX_TOTAL_BYTES = 48 << 20
    public static let MAX_ENTRIES = 2000
    /** Folders inside an archive. */
    public static let MAX_DEPTH = 8
    /** Expansion ratio above which an entry larger than [RATIO_MIN_BYTES] is treated as a ZIP bomb. */
    public static let MAX_RATIO = 200
    public static let RATIO_MIN_BYTES = 1 << 20
    /** Documents handled from one selection. */
    public static let MAX_PICKED = 32

    public enum Kind { case source, compressed, archive }

    /** The kind by name only (any case): .HC, .HC.Z or .zip; nil for anything else. */
    public static func kind(_ name: String) -> Kind? {
        let n = name.trimmed().lowercased()
        if n.hasSuffix(".zip") && n.count > 4 { return .archive }
        if n.hasSuffix(".hc.z") && n.count > 5 { return .compressed }
        if n.hasSuffix(".hc") && n.count > 3 { return .source }
        return nil
    }

    /** One picked file after [prepare]: staged ([error] nil) or refused. */
    public final class Prepared {
        /** The picked document's own name (for messages). */
        public let source: String
        public let error: Error?
        public let kind: Kind?
        /** The name it is published under in [DESTINATION] (a TempleOS byte string). */
        public let name: String
        public let isDir: Bool
        /** Files staged (an archive's count; 1 otherwise). */
        public let files: Int
        let stage: LayeredFs.Stage?
        init(_ source: String, error: Error) { self.source = FileImport.shown(source); self.error = error; kind = nil; name = ""; isDir = false; files = 0; stage = nil }
        init(_ source: String, _ kind: Kind, _ name: String, _ isDir: Bool, _ files: Int, _ stage: LayeredFs.Stage) {
            self.source = FileImport.shown(source); error = nil; self.kind = kind; self.name = name; self.isDir = isDir; self.files = files; self.stage = stage
        }
    }

    /** A picked file that is not imported at all (deletes its copy). */
    public static func refuse(_ p: PickedFile, _ e: ImportError) -> Prepared {
        if let h = p.hostPath { _ = HostFile.delete(h) }
        return Prepared(p.name, error: e)
    }

    /**
     * Reads, checks and decodes [p] into a staging folder of [fs]; deletes the platform's copy. Any thread (the
     * drive is thread-safe). The result is refused with the reason, or staged and invisible until [publish].
     */
    public static func prepare(_ fs: LayeredFs, _ p: PickedFile) -> Prepared {
        defer { if let h = p.hostPath { _ = HostFile.delete(h) } }
        do {
            if let problem = p.problem { throw problem }
            guard let host = p.hostPath, HostFile.isFile(host) else { throw ImportError("import.error.read") }
            guard let kind = kind(p.name) else { throw ImportError("import.error.unsupported_type") }
            let size = HostFile.length(host)
            if size == 0 { throw ImportError("import.error.empty") }
            if kind == .archive {
                if size > Int64(MAX_ARCHIVE_BYTES) { throw ImportError("import.error.archive_too_large", ("mib", MAX_ARCHIVE_BYTES >> 20)) }
                return try prepareArchive(fs, host, p.name)
            }
            if size > Int64(MAX_FILE_BYTES) { throw ImportError("import.error.too_large", ("mib", MAX_FILE_BYTES >> 20)) }
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: host)) else { throw ImportError("import.error.read") }
            var bytes = [UInt8](d)
            var name = p.name.trimmed()
            if kind == .compressed {
                guard let h = TempleArc.header(bytes) else { throw ImportError("import.error.corrupt_z") }
                if h.expanded > MAX_FILE_BYTES { throw ImportError("import.error.too_large", ("mib", MAX_FILE_BYTES >> 20)) }
                do { bytes = try TempleArc.expand(bytes, limit: MAX_FILE_BYTES) } catch { throw ImportError("import.error.corrupt_z") }
                name = String(name.unicodeScalars.dropLast(2))
            } else {
                // the bytes are stored unchanged; only content that is certainly something else is refused
                if bytes.starts(with: [0x50, 0x4B, 3, 4]) || bytes.starts(with: [0x50, 0x4B, 5, 6]) { throw ImportError("import.error.is_zip") }
                if let h = TempleArc.header(bytes), h.compressed == bytes.count, (try? TempleArc.expand(bytes, limit: MAX_FILE_BYTES)) != nil {
                    throw ImportError("import.error.is_compressed")
                }
            }
            guard let driveName = driveName(name) else { throw ImportError("import.error.bad_name", ("entry", shown(name))) }
            let stage = try fs.beginStage()
            do { try fs.stageFile(stage, driveName, bytes) } catch { fs.discardStage(stage); throw error }
            return Prepared(p.name, kind, driveName, false, 1, stage)
        } catch {
            return Prepared(p.name, error: error)
        }
    }

    /** An archive entry's name: Unicode for messages, and the C: byte string (nil when it cannot be one). */
    static func entryName(_ e: ZipArchive.Entry) -> (shown: String, bytes: String?) {
        // flag 11 marks UTF-8; macOS and Linux tools write UTF-8 without it, so valid UTF-8 with non-ASCII counts too
        let utf8 = e.utf8 || (e.rawName.contains { $0 >= 0x80 } && String(bytes: e.rawName, encoding: .utf8) != nil)
        if utf8 {
            guard let u = String(bytes: e.rawName, encoding: .utf8) else { return ("?", nil) }
            let name = u.replacingOccurrences(of: "\\", with: "/")
            return (shown(name), InputCharacterPolicy.encode(name, singleLine: true))
        }
        // CP437, the ZIP default, is also TempleOS's character set: the bytes are the name
        let bytes = String(String.UnicodeScalarView(e.rawName.map { Unicode.Scalar($0) })).replacingOccurrences(of: "\\", with: "/")
        return (shown(InputCharacterPolicy.display(bytes)), bytes)
    }

    /** [s] for a message: control, line-separator and bidi-control characters become "?" (a name cannot add lines or reorder text). */
    public static func shown(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { c -> Unicode.Scalar in
            let v = c.value
            return v < 0x20 || (v >= 0x7F && v < 0xA0) || v == 0x2028 || v == 0x2029 || v == 0x061C || (0x200E...0x200F).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) ? "?" : c
        }))
    }

    /** A provider's or archive's name as one C: name (NFC, CP437), or nil when it cannot be one. */
    public static func driveName(_ unicode: String) -> String? {
        let t = unicode.trimmed()
        guard !t.isEmpty, let bytes = InputCharacterPolicy.encode(t, singleLine: true), validSegment(bytes) else { return nil }
        return bytes
    }

    /**
     * One RedSea name ([Paths.normalize]: at most 38 characters, no : * ? " < > |), not hidden from listings, not ending
     * in .Z (the drive reads X.Z as X), and not starting or ending with a character either platform trims from a path
     * (spaces and controls; also CP437 a-grave 0x85 and a-acute 0xA0, which Swift's trimming treats as whitespace).
     */
    static func validSegment(_ b: String) -> Bool {
        if b.isEmpty || b == "." || b == ".." || b.contains("/") || b.contains("\\") || b.hasPrefix(".tmp-") || b.uppercased().hasSuffix(".Z") { return false }
        func trimmable(_ c: Unicode.Scalar?) -> Bool { guard let v = c?.value else { return true }; return v <= 0x20 || v == 0x85 || v == 0xA0 }
        if trimmable(b.unicodeScalars.first) || trimmable(b.unicodeScalars.last) { return false }
        return Paths.normalize(DESTINATION, b) == DESTINATION + "/" + b
    }

    private static func zipError(_ e: ZipError, _ entry: String?) -> ImportError {
        switch e {
        case .invalid: return ImportError("import.error.invalid_zip")
        case .unsupported: return ImportError("import.error.zip_unsupported")
        case .tooManyEntries: return ImportError("import.error.too_many_entries", ("count", MAX_ENTRIES))
        case .damaged: return ImportError("import.error.damaged", ("entry", entry ?? "?"))
        case .read: return ImportError("import.error.read")
        }
    }

    private struct Item {
        let entry: ZipArchive.Entry
        let shown: String
        let parts: [String]
        let expand: Bool
    }

    /**
     * Checks every entry of the archive at [host] before extracting any: no encryption or unsupported method, no
     * link or special file, names that are valid C: names and stay inside the import folder (no "..", absolute
     * path or drive), no two entries whose names differ only in case (the drive ignores case), no file that is
     * also a folder, the depth, size, ratio and total limits. Then extracts into a staging folder: one folder of
     * the archive that holds everything becomes the import folder, otherwise a folder named after the archive.
     */
    private static func prepareArchive(_ fs: LayeredFs, _ host: String, _ source: String) throws -> Prepared {
        let zip: ZipArchive
        do { zip = try ZipArchive(host, maxEntries: MAX_ENTRIES) } catch let e as ZipError { throw zipError(e, nil) }
        defer { zip.close() }
        var items: [Item] = []
        var files = Set<String>(), dirs = Set<String>()
        /** The first spelling of each folder (lower-case path): "A/Sub" and "A/SUB" are one folder on C:. */
        var spelling: [String: String] = [:]
        var total = 0
        for e in zip.entries {
            let (shown, b) = entryName(e)
            if e.flags & 0x41 != 0 || e.method == 99 { throw ImportError("import.error.encrypted") }
            if e.isSpecial { throw ImportError("import.error.link", ("entry", shown)) }
            guard let bytes = b else { throw ImportError("import.error.bad_name", ("entry", shown)) }
            if bytes.hasPrefix("/") || bytes.contains(":") { throw ImportError("import.error.unsafe_path", ("entry", shown)) }
            var parts = bytes.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
            if e.isDir && parts.count > 1 && parts.last == "" { parts.removeLast() }
            if parts.contains(where: { $0 == "." || $0 == ".." }) { throw ImportError("import.error.unsafe_path", ("entry", shown)) }
            if parts.contains(where: { $0.isEmpty }) { throw ImportError("import.error.bad_name", ("entry", shown)) }
            // Finder's resource forks and folder settings are not content
            if parts[0] == "__MACOSX" || parts[parts.count - 1] == ".DS_Store" { continue }
            if !e.isDir && e.method != 0 && e.method != 8 { throw ImportError("import.error.method", ("entry", shown)) }
            var expand = false
            let last = parts[parts.count - 1]
            if !e.isDir && last.unicodeScalars.count > 2 && last.uppercased().hasSuffix(".Z") {
                parts[parts.count - 1] = String(last.unicodeScalars.dropLast(2)); expand = true
            }
            if !parts.allSatisfy(validSegment) { throw ImportError("import.error.bad_name", ("entry", shown)) }
            for k in 0..<(e.isDir ? parts.count : parts.count - 1) {
                let folder = parts[0...k].joined(separator: "/").lowercased()
                if let first = spelling[folder] { parts[k] = first } else { spelling[folder] = parts[k] }
            }
            if parts.count - (e.isDir ? 0 : 1) > MAX_DEPTH { throw ImportError("import.error.too_deep", ("entry", shown), ("count", MAX_DEPTH)) }
            if !e.isDir {
                if e.size > MAX_FILE_BYTES { throw ImportError("import.error.entry_too_large", ("entry", shown), ("mib", MAX_FILE_BYTES >> 20)) }
                if e.size > RATIO_MIN_BYTES && e.size / max(1, e.compressedSize) > MAX_RATIO { throw ImportError("import.error.ratio", ("entry", shown)) }
                total += e.size
                if total > MAX_TOTAL_BYTES { throw ImportError("import.error.expands_too_large", ("mib", MAX_TOTAL_BYTES >> 20)) }
            }
            let key = parts.joined(separator: "/").lowercased()
            if e.isDir {
                if files.contains(key) { throw ImportError("import.error.file_and_folder", ("entry", shown)) }
                dirs.insert(key)
            } else {
                if files.contains(key) { throw ImportError("import.error.duplicate", ("entry", shown)) }
                if dirs.contains(key) { throw ImportError("import.error.file_and_folder", ("entry", shown)) }
                files.insert(key)
            }
            for k in stride(from: 1, to: parts.count, by: 1) {
                let parent = parts[0..<k].joined(separator: "/").lowercased()
                if files.contains(parent) { throw ImportError("import.error.file_and_folder", ("entry", shown)) }
                dirs.insert(parent)
            }
            items.append(Item(entry: e, shown: shown, parts: parts, expand: expand))
        }
        // a file listed before a folder of the same name
        if let clash = items.first(where: { !$0.entry.isDir && dirs.contains($0.parts.joined(separator: "/").lowercased()) }) {
            throw ImportError("import.error.file_and_folder", ("entry", clash.shown))
        }
        if files.isEmpty { throw ImportError("import.error.empty_archive") }
        let top = items[0].parts[0].lowercased()
        let single = items.allSatisfy { $0.parts[0].lowercased() == top && ($0.parts.count > 1 || $0.entry.isDir) }
        let folder: String
        if single { folder = items.first { $0.parts.count > 1 }?.parts[0] ?? items[0].parts[0] } else {
            let base = String(source.trimmed().unicodeScalars.dropLast(4))
            guard let n = driveName(base) else { throw ImportError("import.error.bad_name", ("entry", shown(base))) }
            folder = n
        }
        let stage = try fs.beginStage()
        do {
            try fs.stageDir(stage, folder)
            var count = 0
            for it in items {
                let rel = ([folder] + it.parts.dropFirst(single ? 1 : 0)).joined(separator: "/")
                if it.entry.isDir { try fs.stageDir(stage, rel); continue }
                var data: [UInt8]
                do { data = try zip.data(it.entry) } catch let e as ZipError { throw zipError(e, it.shown) }
                if it.expand {
                    guard let h = TempleArc.header(data) else { throw ImportError("import.error.corrupt_z_entry", ("entry", it.shown)) }
                    if h.expanded > MAX_FILE_BYTES { throw ImportError("import.error.entry_too_large", ("entry", it.shown), ("mib", MAX_FILE_BYTES >> 20)) }
                    total += h.expanded - data.count
                    if total > MAX_TOTAL_BYTES { throw ImportError("import.error.expands_too_large", ("mib", MAX_TOTAL_BYTES >> 20)) }
                    do { data = try TempleArc.expand(data, limit: MAX_FILE_BYTES) } catch { throw ImportError("import.error.corrupt_z_entry", ("entry", it.shown)) }
                }
                try fs.stageFile(stage, rel, data)
                count += 1
            }
            return Prepared(source, .archive, folder, true, count, stage)
        } catch {
            fs.discardStage(stage)
            throw error
        }
    }

    /** Makes [p] visible as [DESTINATION]/[name]; [replace] replaces the user's earlier file or folder there. UI thread. */
    @discardableResult
    public static func publish(_ fs: LayeredFs, _ p: Prepared, as name: String, replace: Bool) throws -> String {
        guard let stage = p.stage else { throw p.error ?? ImportError("import.error.interrupted") }
        for d in ["C:/Home", DESTINATION] where !fs.isDir(d) { try fs.mkdir(d) }
        let target = DESTINATION + "/" + name
        try fs.publishStaged(stage, p.name, target, replace: replace)
        return target
    }

    /** Deletes what [p] still holds (after [publish]: a replaced entry; otherwise everything staged). */
    public static func discard(_ fs: LayeredFs, _ p: Prepared) { if let s = p.stage { fs.discardStage(s) } }

    /** Keep Both: "Name.HC" -> "Name_2.HC", "Name_3.HC", ... the first free valid name in [DESTINATION], or nil. */
    public static func freeName(_ fs: LayeredFs, _ name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        let dot = scalars.firstIndex(of: ".").flatMap { $0 > 0 ? $0 : nil } ?? scalars.count
        let ext = Array(scalars[dot...])
        for n in 2...999 {
            let suffix = Array("_\(n)".unicodeScalars)
            var base = Array(scalars[..<dot])
            while !base.isEmpty && base.count + suffix.count + ext.count > 38 { base.removeLast() }
            let candidate = String(String.UnicodeScalarView(base + suffix + ext))
            if validSegment(candidate) && !fs.exists(DESTINATION + "/" + candidate) { return candidate }
        }
        return nil
    }

    /** [e] as the reason shown after the file's name. */
    public static func reason(_ e: Error) -> String {
        if let i = e as? ImportError { return L10n.trArgs(i.key, i.args) }
        if let f = e as? FsError { return f.localized() }
        return tr("import.error.interrupted")
    }
}
