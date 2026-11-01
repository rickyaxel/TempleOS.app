import Foundation

// Port of kernel/LayeredFs.kt.

/** Read-only bundled C:/ drive (app assets). Paths are relative, e.g. "Demo/Games/Maze.HC". */
public protocol BundleSource: AnyObject {
    /** Contents of bundled-fs.index. */
    func index() -> String
    func open(_ rel: String) -> [UInt8]?
}

/** Bundle backed by a host directory plus its index file (tests, tools). */
public final class DirBundle: BundleSource {
    private let root: URL
    private let indexFile: URL
    public init(_ root: URL, _ indexFile: URL) { self.root = root; self.indexFile = indexFile }
    public func index() -> String {
        // Kotlin readText() throws when the index is missing; here it reads as empty.
        guard let d = try? Data(contentsOf: indexFile) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    public func open(_ rel: String) -> [UInt8]? {
        let f = root.appendingPathComponent(rel)
        guard HostFile.isFile(f.path), let d = try? Data(contentsOf: f) else { return nil }
        return [UInt8](d)
    }
}

/** java.io.File-like helpers on host paths (FileManager / POSIX). */
enum HostFile {
    static var fm: FileManager { FileManager.default }
    static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
    static func isDirectory(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    static func isFile(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && !d.boolValue }
    /** File.length(): 0 when missing. */
    static func length(_ p: String) -> Int64 {
        guard let a = try? fm.attributesOfItem(atPath: p), let n = a[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }
    /** File.lastModified(): epoch milliseconds, 0 when missing. */
    static func lastModified(_ p: String) -> Int64 {
        guard let a = try? fm.attributesOfItem(atPath: p), let d = a[.modificationDate] as? Date else { return 0 }
        return Int64((d.timeIntervalSince1970 * 1000).rounded(.down))
    }
    static func name(_ p: String) -> String { (p as NSString).lastPathComponent }
    static func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    static func child(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }
    /** File.listFiles(): full child paths, or nil if not a readable directory. */
    static func listFiles(_ p: String) -> [String]? {
        guard isDirectory(p), let names = try? fm.contentsOfDirectory(atPath: p) else { return nil }
        return names.map { child(p, $0) }
    }
    /** File.walkTopDown().filter { isFile }.sumOf { length } */
    static func treeSize(_ p: String) -> Int64 {
        if isFile(p) { return length(p) }
        var sum: Int64 = 0
        for c in listFiles(p) ?? [] { sum += treeSize(c) }
        return sum
    }
    /** File.mkdirs() */
    static func mkdirs(_ p: String) { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
    /** File.delete(): a file or an empty directory. */
    static func delete(_ p: String) -> Bool { Foundation.remove(p) == 0 }
    /** File.deleteRecursively() */
    static func deleteRecursively(_ p: String) -> Bool {
        if !exists(p) { return true }
        return (try? fm.removeItem(atPath: p)) != nil
    }
    /** File.renameTo(): POSIX rename (replaces an existing target atomically). */
    static func renameTo(_ from: String, _ to: String) -> Bool { Foundation.rename(from, to) == 0 }
    /** The path as spelled on disk (exact case), via fcntl(F_GETPATH). */
    static func onDiskPath(_ p: String) -> String? {
        let fd = Foundation.open(p, O_RDONLY)
        if fd < 0 { return nil }
        defer { _ = Foundation.close(fd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        if fcntl(fd, F_GETPATH, &buf) < 0 { return nil }
        return String(cString: buf)
    }
    /** File.canonicalPath: symlinks resolved for the existing prefix, the rest normalized. */
    static func canonicalPath(_ p: String) -> String {
        let std = (p as NSString).standardizingPath
        var head = std
        var tail: [String] = []
        while !head.isEmpty && head != "/" && !exists(head) {
            tail.insert(name(head), at: 0)
            head = parent(head)
        }
        var resolved = head
        if let r = realpath(head, nil) { resolved = String(cString: r); free(r) }
        for c in tail { resolved = child(resolved, c) }
        return resolved
    }
}

/**
 * The TempleOS Mobile virtual filesystem: an immutable bundled layer with a
 * writable overlay stored under [overlayRoot] (inside the app sandbox).
 *
 * - Logical paths are absolute "C:/..." paths; [Paths.normalize] rejects
 *   anything that could escape (no drive other than C:, no ".." past root).
 * - Writes go to the overlay (copy-on-write over bundled files) atomically:
 *   data is written to a temp file, synced, then renamed.
 * - Deleting a bundled file records a whiteout so it disappears from listings.
 * - The overlay is limited to [quotaBytes].
 *
 * Thread-safe (all public methods synchronized with a recursive lock).
 */
public final class LayeredFs: VirtualFs {
    /** [modified]: the ISO's wall-clock date in ms (V-04), 0 if unknown. [origin]: the index's provenance field. */
    private final class BEntry {
        let path: String, isDir: Bool, size: Int64, modified: Int64, origin: String
        init(_ path: String, _ isDir: Bool, _ size: Int64, _ modified: Int64 = 0, _ origin: String = "") {
            self.path = path; self.isDir = isDir; self.size = size; self.modified = modified; self.origin = origin
        }
    }

    private let bundle: BundleSource
    private let overlayRoot: String
    private let quotaBytes: Int64
    private let lock = NSRecursiveLock()

    private var bundled: [String: BEntry] = [:]              // lower-case logical path -> entry
    private var bundledChildren: [String: [BEntry]] = [:]    // lower-case dir -> children
    private let filesDir: String
    private let whiteoutFile: String
    private var whiteouts = Set<String>()                    // lower-case logical paths
    private var used: Int64 = 0

    public convenience init(_ bundle: BundleSource, _ overlayRoot: URL, quotaBytes: Int64 = 64 << 20) {
        self.init(bundle, overlayRoot.path, quotaBytes: quotaBytes)
    }

    public init(_ bundle: BundleSource, _ overlayRoot: String, quotaBytes: Int64 = 64 << 20) {
        self.bundle = bundle
        self.overlayRoot = overlayRoot
        self.quotaBytes = quotaBytes
        filesDir = HostFile.child(overlayRoot, "files")
        whiteoutFile = HostFile.child(overlayRoot, "deleted.txt")
        HostFile.mkdirs(filesDir)
        bundled["c:/"] = BEntry("C:/", true, 0)
        for line in LayeredFs.splitScalars(bundle.index(), "\n") {
            let f = LayeredFs.splitScalars(line, "\t")
            if f.count < 3 { continue }
            let path = "C:/" + f[1]
            let e = BEntry(path, f[0] == "D", Int64(f[2]) ?? 0, f.count > 5 ? Int64(f[5]) ?? 0 : 0, f.count > 4 && f[4] != "-" ? f[4] : "")
            bundled[path.lowercased()] = e
            bundledChildren[Paths.parent(path).lowercased(), default: []].append(e)
        }
        if HostFile.exists(whiteoutFile), let d = try? Data(contentsOf: URL(fileURLWithPath: whiteoutFile)) {
            for l in LayeredFs.readLines(String(decoding: d, as: UTF8.self)) where !LayeredFs.isBlank(l) { whiteouts.insert(l) }
        }
        used = HostFile.treeSize(filesDir)
    }

    // ------------------------------------------------------------ text helpers (Kotlin semantics)

    /** Kotlin split(c): on a single scalar ("\r\n" is not one unit), keeping empty parts. */
    private static func splitScalars(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        var res: [String] = []
        var cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if c == sep { res.append(String(cur)); cur = String.UnicodeScalarView() } else { cur.append(c) }
        }
        res.append(String(cur))
        return res
    }

    /** Kotlin readLines(): lines ended by \n, \r or \r\n (no trailing empty line). */
    private static func readLines(_ s: String) -> [String] {
        var res: [String] = []
        var cur = String.UnicodeScalarView()
        var prevCR = false
        var pending = false
        for c in s.unicodeScalars {
            if c == "\n" && prevCR { prevCR = false; continue }
            prevCR = false
            if c == "\n" || c == "\r" {
                res.append(String(cur)); cur = String.UnicodeScalarView(); pending = false
                prevCR = c == "\r"
            } else { cur.append(c); pending = true }
        }
        if pending { res.append(String(cur)) }
        return res
    }

    /** Kotlin isBlank(): empty or only Char.isWhitespace characters. */
    private static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { c in
            let v = c.value
            return (v >= 9 && v <= 13) || (v >= 28 && v <= 32) || c.properties.isWhitespace && v != 0x85
        }
    }

    private static func removePrefix(_ s: String, _ p: String) -> String { s.hasPrefix(p) ? String(s.dropFirst(p.count)) : s }

    // ------------------------------------------------------------ mapping

    private func check(_ path: String) throws -> String {
        guard let p = Paths.normalize("C:/", path) else { throw FsError("Invalid path: \(path)", "fs.error.invalid_path", ["path": path]) }
        return p
    }

    /** Host file for a logical path; never outside [filesDir]. */
    private func hostFile(_ logical: String) throws -> String {
        let rel = LayeredFs.removePrefix(logical, "C:/")
        let f = rel.isEmpty ? filesDir : HostFile.child(filesDir, rel)
        let canon = HostFile.canonicalPath(f)
        if !canon.hasPrefix(HostFile.canonicalPath(filesDir)) { throw FsError("Invalid path: \(logical)", "fs.error.invalid_path", ["path": logical]) }
        return f
    }

    /** Overlay file matching [logical] case-insensitively, or nil. */
    private func overlayFind(_ logical: String) throws -> String? {
        let direct = try hostFile(logical)
        // Kotlin targets case-sensitive storage, where `direct` exists only with the exact
        // case. Apple volumes are usually case-insensitive, so accept `direct` only when its
        // on-disk spelling matches; otherwise fall back to the case-insensitive walk (same
        // names as on Android).
        if HostFile.exists(direct) {
            let rel = LayeredFs.removePrefix(logical, "C:/")
            if rel.isEmpty { return direct }
            if let real = HostFile.onDiskPath(direct), real.hasSuffix("/" + rel) { return direct }
        }
        let parts = LayeredFs.splitScalars(LayeredFs.removePrefix(logical, "C:/"), "/").filter { !$0.isEmpty }
        var cur = filesDir
        for p in parts {
            guard let next = HostFile.listFiles(cur)?.first(where: { HostFile.name($0).lowercased() == p.lowercased() }) else { return nil }
            cur = next
        }
        return cur
    }

    private func isWhiteout(_ logical: String) -> Bool {
        var p = logical.lowercased()
        while true {
            if whiteouts.contains(p) { return true }
            if p == "c:/" || !p.contains("/") { return false }
            let parent = Paths.parent(p).lowercased()
            if parent == p { return false }
            p = parent
        }
    }

    private func bundledEntry(_ logical: String) -> BEntry? {
        isWhiteout(logical) ? nil : (bundled[logical.lowercased()] ?? (logical.lowercased().hasSuffix(".z") && !isWhiteout(String(logical.dropLast(2))) ? bundled[String(logical.dropLast(2)).lowercased()] : nil))
    }

    // ------------------------------------------------------------ queries
    // Kotlin's hostFile() throws FsError (an unchecked exception) from the queries too;
    // in Swift the non-throwing queries treat that as "absent".

    public func readFile(_ path: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return nil }
        if let f = (try? overlayFind(p)) ?? (p.lowercased().hasSuffix(".z") ? (try? overlayFind(String(p.dropLast(2)))) : nil) {
            if HostFile.isFile(f), let d = try? Data(contentsOf: URL(fileURLWithPath: f)) { return [UInt8](d) } else { return nil }
        }
        guard let e = bundledEntry(p) else { return nil }
        if e.isDir { return nil }
        return bundle.open(LayeredFs.removePrefix(e.path, "C:/"))
    }

    public func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return false }
        return (try? overlayFind(p)) != nil || (p.lowercased().hasSuffix(".z") && (try? overlayFind(String(p.dropLast(2)))) != nil) || bundledEntry(p) != nil
    }

    public func isDir(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return false }
        if p == "C:/" { return true }
        if let f = (try? overlayFind(p)) { return HostFile.isDirectory(f) }
        return bundledEntry(p)?.isDir ?? false
    }

    public func stat(_ path: String) -> FsEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return nil }
        if let f = (try? overlayFind(p)) {
            return FsEntry(HostFile.name(f), p, HostFile.isDirectory(f), HostFile.isFile(f) ? HostFile.length(f) : 0, HostFile.lastModified(f), false)
        }
        guard let e = bundledEntry(p) else { return nil }
        let n = Paths.name(e.path)
        return FsEntry(n.isEmpty ? "C:" : n, e.path, e.isDir, e.size, e.modified, true)
    }

    public func list(_ dir: String) -> [FsEntry]? {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", dir) else { return nil }
        if !isDir(p) { return nil }
        // LinkedHashMap: a replaced key keeps its first position
        var order: [String] = []
        var res: [String: FsEntry] = [:]
        func put(_ k: String, _ v: FsEntry) { if res.updateValue(v, forKey: k) == nil { order.append(k) } }
        if !isWhiteout(p) || p == "C:/" {
            for e in bundledChildren[p.lowercased()] ?? [] {
                if isWhiteout(e.path) { continue }
                put(Paths.name(e.path).lowercased(), FsEntry(Paths.name(e.path), e.path, e.isDir, e.size, e.modified, true))
            }
        }
        if let of = (try? overlayFind(p)), let files = HostFile.listFiles(of) {
            for f in files {
                let name = HostFile.name(f)
                if name.hasPrefix(".tmp-") { continue }
                let lp = p == "C:/" ? "C:/\(name)" : "\(p)/\(name)"
                put(name.lowercased(), FsEntry(name, lp, HostFile.isDirectory(f), HostFile.isFile(f) ? HostFile.length(f) : 0, HostFile.lastModified(f), false))
            }
        }
        return order.map { res[$0]! }
    }

    public func isReadOnly(_ path: String) -> Bool { false }

    // ------------------------------------------------------------ mutations

    private func ensureParentDir(_ logical: String) throws {
        let parent = Paths.parent(logical)
        if parent != "C:/" && !isDir(parent) { throw FsError("Directory not found: \(parent)", "fs.error.dir_not_found", ["path": parent]) }
        let hp = try hostFile(parent)
        HostFile.mkdirs(hp)
    }

    public func writeFile(_ path: String, _ data: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let p = try check(path)
        if p == "C:/" { throw FsError("Invalid path: \(path)", "fs.error.invalid_path", ["path": path]) }
        if isDir(p) { throw FsError("Is a directory: \(p)", "fs.error.is_directory", ["path": p]) }
        try ensureParentDir(p)
        let target = try overlayFind(p) ?? hostFile(p)
        let old = HostFile.exists(target) ? HostFile.length(target) : 0
        if used - old + Int64(data.count) > quotaBytes {
            throw FsError("Storage full: \(Brand.appName) keeps at most \(quotaBytes >> 20) MiB of your files", "fs.error.storage_full", ["mib": quotaBytes >> 20])
        }
        let tmp = HostFile.child(HostFile.parent(target), ".tmp-\(HostFile.name(target))-\(DispatchTime.now().uptimeNanoseconds)")
        // Kotlin: FileOutputStream + fd.sync() inside try/catch(IOException); the rename
        // failure's FsError is not an IOException and passes through.
        do {
            let fd = Foundation.open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd < 0 { throw LayeredFs.IOError("\(tmp) (\(String(cString: strerror(errno))))") }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try h.write(contentsOf: Data(data))
                try h.synchronize()
                try h.close()
            } catch {
                try? h.close()
                throw LayeredFs.IOError((error as NSError).localizedDescription)
            }
        } catch let e as LayeredFs.IOError {
            _ = HostFile.delete(tmp)
            throw FsError("Could not save \(p): \(e.message)", "fs.error.could_not_save", ["path": p])
        }
        if !HostFile.renameTo(tmp, target) {
            _ = HostFile.delete(target)
            if !HostFile.renameTo(tmp, target) { throw FsError("Could not save \(p)", "fs.error.could_not_save", ["path": p]) }
        }
        used += Int64(data.count) - old
        try unWhiteout(p)
    }

    /** java.io.IOException equivalent (message text as on the JVM where possible). */
    private struct IOError: Error { let message: String; init(_ m: String) { message = m } }

    private func unWhiteout(_ p: String) throws {
        var q = p.lowercased()
        var changed = false
        while true {
            if whiteouts.remove(q) != nil { changed = true }
            if q == "c:/" { break }
            q = Paths.parent(q).lowercased()
        }
        if changed { try saveWhiteouts { FsError("Could not save \(p)", "fs.error.could_not_save", ["path": p]) } }
    }

    /**
     * Persists the deleted-bundled-files list atomically. A failure (storage full, I/O error) is
     * reported as `failure`'s FsError, which the Files and Editor windows show; it was silently
     * dropped, so a deleted original came back on the next launch.
     */
    private func saveWhiteouts(_ failure: () -> FsError) throws {
        let tmp = HostFile.child(overlayRoot, "deleted.txt.tmp")
        let ok = (try? Data(whiteouts.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: tmp))) != nil && HostFile.renameTo(tmp, whiteoutFile)
        if !ok { _ = HostFile.delete(tmp); throw failure() }
    }

    public func mkdir(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = try check(path)
        if exists(p) { if isDir(p) { return } else { throw FsError("A file named \(Paths.name(p)) exists", "fs.error.file_exists", ["name": Paths.name(p)]) } }
        try ensureParentDir(p)
        HostFile.mkdirs(try hostFile(p))
        try unWhiteout(p)
    }

    public func delete(_ path: String, recursive: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let p = try check(path)
        if p == "C:/" { throw FsError("Cannot delete the drive", "fs.error.delete_drive") }
        if !exists(p) { throw FsError("File not found: \(p)", "fs.error.not_found", ["path": p]) }
        if isDir(p) && !recursive && !list(p)!.isEmpty { throw FsError("Directory not empty: \(p)", "fs.error.dir_not_empty", ["path": p]) }
        if let f = try overlayFind(p) {
            let freed = HostFile.treeSize(f)
            if !HostFile.deleteRecursively(f) { throw FsError("Could not delete \(p)", "fs.error.could_not_delete", ["path": p]) }
            used -= freed
        }
        if bundled[p.lowercased()] != nil && whiteouts.insert(p.lowercased()).inserted {
            // not persisted: the original would come back on the next launch, so the delete did not happen
            try saveWhiteouts { whiteouts.remove(p.lowercased()); return FsError("Could not delete \(p)", "fs.error.could_not_delete", ["path": p]) }
        }
    }

    public func move(_ from: String, _ to: String) throws {
        lock.lock(); defer { lock.unlock() }
        let a = try check(from); let b = try check(to)
        if !exists(a) { throw FsError("File not found: \(a)", "fs.error.not_found", ["path": a]) }
        if exists(b) { throw FsError("Already exists: \(b)", "fs.error.already_exists", ["path": b]) }
        if b.lowercased().hasPrefix(a.lowercased() + "/") { throw FsError("Cannot move a directory into itself", "fs.error.move_into_itself") }
        if isDir(a) {
            try mkdir(b)
            for e in list(a)! { try move(e.path, "\(b)/\(e.name)") }
            try delete(a, recursive: true)
        } else {
            guard let data = readFile(a) else { throw FsError("Could not read \(a)", "fs.error.could_not_read", ["path": a]) }
            try writeFile(b, data)
            try delete(a)
        }
    }

    /** True if [path] is a bundled original that the user has not modified. */
    public func isOriginal(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return false }
        return (try? overlayFind(p)) == nil && bundledEntry(p) != nil
    }

    /// Immutable source bytes, independent of an edited overlay document.
    public func bundledBytes(_ path:String)->[UInt8]? {
        lock.lock();defer {lock.unlock()}
        guard let p=Paths.normalize("C:/",path),let e=bundled[p.lowercased()] ?? (p.lowercased().hasSuffix(".z") ? bundled[String(p.dropLast(2)).lowercased()] : nil),!e.isDir else {return nil}
        return bundle.open(String(e.path.dropFirst(3)))
    }

    /** True if a bundled original exists at [path] (whether or not the user changed it). */
    public func hasBundledOriginal(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path) else { return false }
        return bundled[p.lowercased()] != nil
    }

    /**
     * Where the bundled file at [path] comes from (bundled-fs.index, written by
     * tools/resource-packaging/build_bundled_fs.py), or nil if no bundled file is there.
     */
    public func bundledOrigin(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = Paths.normalize("C:/", path), let e = bundled[p.lowercased()], !e.isDir else { return nil }
        return e.origin
    }

    /** Removes the user's copy of a bundled file, restoring the original. */
    public func restoreOriginal(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = try check(path)
        if let f = try overlayFind(p) { used -= HostFile.length(f); _ = HostFile.delete(f) }
        try unWhiteout(p)
    }

    public func usedBytes() -> Int64 { lock.lock(); defer { lock.unlock() }; return used }
    public var quota: Int64 { quotaBytes }
}
