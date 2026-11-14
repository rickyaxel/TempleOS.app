import Compression
import CryptoKit
import Foundation
import XCTest
@testable import TempleCore

/**
 * Start menu > Import... (docs/file-import.md): type detection, TempleOS compression against TempleOS's own
 * TOSZ output, the ZIP reader and the archive policy on adversarial input, the drive's staging and recovery,
 * the flow through the real shell (first-time explanation, picker, collisions, summary), and genuine external
 * programs (shared/test-vectors/import) found in Files and run on the HolyC interpreter. Port of ImportTest.kt.
 */
final class ImportTests: XCTestCase {
    private let FIX = SHARED.appendingPathComponent("test-vectors/import")
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
        dirs = []
    }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-import-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return u
    }

    private func drive(_ dir: URL, quota: Int64 = 64 << 20) -> LayeredFs {
        LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")),
                  dir.appendingPathComponent("drive"), quotaBytes: quota)
    }

    private func fixture(_ name: String) -> [UInt8] { readFileBytes(FIX.appendingPathComponent(name))! }

    /** A private copy of [bytes], as a platform picker hands a document over. */
    private func picked(_ name: String, _ bytes: [UInt8]) -> PickedFile {
        let u = tmp().appendingPathComponent("copy")
        try! Data(bytes).write(to: u)
        return PickedFile(name: name, hostPath: u.path)
    }

    private func sha(_ b: [UInt8]) -> String { SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined() }

    /** Staging folders left in the overlay (must be none after every import, failed or not). */
    private func leftovers(_ dir: URL, _ files: String = "drive/files") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(files).path)) ?? []).filter { $0.hasPrefix(".tmp-") }
    }

    private func key(_ p: FileImport.Prepared) -> String? { (p.error as? ImportError)?.key ?? (p.error as? FsError)?.key }

    /** Prepares and publishes [p] like the flow does with a free name; returns the published path. */
    @discardableResult
    private func importNow(_ fs: LayeredFs, _ p: PickedFile) throws -> String {
        let r = FileImport.prepare(fs, p)
        if let e = r.error { throw e }
        defer { FileImport.discard(fs, r) }
        return try FileImport.publish(fs, r, as: r.name, replace: false)
    }

    // ------------------------------------------------------------ ZIP writer for adversarial archives

    private struct ZEntry {
        var name: [UInt8]
        var data: [UInt8] = []
        var method = 0
        var flags = 0
        var madeBy = 0x031E          // Unix, ZIP 3.0
        var external = 0o100644 << 16
        var crc: UInt32? = nil
        var size: Int? = nil
        var csize: Int? = nil
        var localName: [UInt8]? = nil
        var raw: [UInt8]? = nil      // compressed bytes as stored, instead of compressing [data]
        init(_ name: String, _ data: [UInt8] = [], method: Int = 0) { self.name = Array(name.utf8); self.data = data; self.method = method }
    }

    private static func deflate(_ src: [UInt8]) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: src.count + 4096)
        let n = src.withUnsafeBufferPointer { s in dst.withUnsafeMutableBufferPointer { d in
            compression_encode_buffer(d.baseAddress!, d.count, s.baseAddress ?? UnsafePointer(d.baseAddress!), s.count, nil, COMPRESSION_ZLIB) } }
        return Array(dst[0..<n])
    }

    private func zip(_ entries: [ZEntry], eocdCount: Int? = nil, disk: Int = 0) -> [UInt8] {
        var out: [UInt8] = [], cd: [UInt8] = []
        func le(_ v: Int, _ n: Int, _ b: inout [UInt8]) { for i in 0..<n { b.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        for e in entries {
            let comp = e.raw ?? (e.method == 8 ? ImportTests.deflate(e.data) : e.data)
            let crc = Int(e.crc ?? Crc32.of(e.data)), size = e.size ?? e.data.count, csize = e.csize ?? comp.count
            let off = out.count, ln = e.localName ?? e.name
            le(0x0403_4B50, 4, &out); le(20, 2, &out); le(e.flags, 2, &out); le(e.method, 2, &out); le(0, 4, &out)
            le(crc, 4, &out); le(csize, 4, &out); le(size, 4, &out); le(ln.count, 2, &out); le(0, 2, &out); out += ln; out += comp
            le(0x0201_4B50, 4, &cd); le(e.madeBy, 2, &cd); le(20, 2, &cd); le(e.flags, 2, &cd); le(e.method, 2, &cd); le(0, 4, &cd)
            le(crc, 4, &cd); le(csize, 4, &cd); le(size, 4, &cd); le(e.name.count, 2, &cd); le(0, 2, &cd); le(0, 2, &cd)
            le(0, 2, &cd); le(0, 2, &cd); le(e.external, 4, &cd); le(off, 4, &cd); cd += e.name
        }
        let cdOff = out.count
        out += cd
        le(0x0605_4B50, 4, &out); le(disk, 2, &out); le(disk, 2, &out)
        le(eocdCount ?? entries.count, 2, &out); le(eocdCount ?? entries.count, 2, &out); le(cd.count, 4, &out); le(cdOff, 4, &out); le(0, 2, &out)
        return out
    }

    /** Imports [entries] as an archive into a fresh drive; returns the refusal key (nil when it was imported). */
    private func archiveKey(_ entries: [ZEntry], file: String = "Test.zip", bytes: [UInt8]? = nil) -> String? {
        let dir = tmp(), fs = drive(dir)
        let used = fs.usedBytes()
        let r = FileImport.prepare(fs, picked(file, bytes ?? zip(entries)))
        if r.error != nil {
            XCTAssertEqual([], leftovers(dir), "a refused archive leaves no staging folder")
            XCTAssertEqual(used, fs.usedBytes(), "a refused archive gives its bytes back")
            XCTAssertFalse(fs.exists(FileImport.DESTINATION), "nothing of a refused archive is visible")
        }
        FileImport.discard(fs, r)
        return key(r)
    }

    // ------------------------------------------------------------ detection

    func testKindIsDecidedByNameNotByMimeOrContent() {
        let cases: [(String, FileImport.Kind?)] = [
            ("Hello.HC", .source), ("hello.hc", .source), ("Hello.Hc", .source), ("  Spaced.HC  ", .source),
            ("Song.HC.Z", .compressed), ("song.hc.z", .compressed), ("Game.zip", .archive), ("GAME.ZIP", .archive),
            ("Archive.HC.zip", .archive), ("Notes.TXT", nil), ("Doc.DD.Z", nil), ("x.Z", nil), ("Hello", nil), ("", nil),
            (".HC", nil), (".zip", nil), ("Hello.HC.txt", nil), ("Hello.HC.Z.zip", .archive), ("Hello.HCZ", nil),
        ]
        for (name, kind) in cases { XCTAssertEqual(FileImport.kind(name), kind, name) }
    }

    // ------------------------------------------------------------ TempleOS compression (genuine files)

    func testGenuineCompressedFilesExpandExactlyAsTempleOSOwnToolDoes() throws {
        // expansions recorded with TOSZ.CPP (TempleOS V5.03 ISO, Downloads/Linux); see shared/test-vectors/import/README.md
        let expected = ["o.HC.Z": ("e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", 437, 2),
                        "B17.HC.Z": ("7b50f52794de6026f2ab9406bfaaf052d62402bbbc31aaeb206e7145879a65b6", 2775, 3),
                        "NewOS.HC.Z": ("49c4b33abba7851d929bdf99b25d5faed38bc4d7fd73509559a61f3c9103d9dc", 1437, 2)]
        for (name, (digest, size, type)) in expected {
            let raw = fixture(name)
            let h = try XCTUnwrap(TempleArc.header(raw), name)
            XCTAssertEqual(raw.count, h.compressed, name); XCTAssertEqual(size, h.expanded, name); XCTAssertEqual(type, h.type, name)
            XCTAssertEqual(digest, sha(try TempleArc.expand(raw, limit: FileImport.MAX_FILE_BYTES)), name)
        }
    }

    func testMalformedCompressedDataIsRefusedWithoutUnboundedWork() throws {
        let raw = fixture("B17.HC.Z")
        for n in 0..<raw.count { XCTAssertThrowsError(try TempleArc.expand(Array(raw.prefix(n)), limit: 1 << 20), "truncated to \(n)") }
        for t: UInt8 in [0, 4, 9, 255] { var b = raw; b[16] = t; XCTAssertThrowsError(try TempleArc.expand(b, limit: 1 << 20), "type \(t)") }
        var small = raw; small[0] = 16; small[1] = 0
        XCTAssertThrowsError(try TempleArc.expand(small, limit: 1 << 20), "compressed size below the header")
        var huge = raw; huge[8] = 0; huge[9] = 0; huge[10] = 0; huge[11] = 0x40 // declares 1 GiB
        XCTAssertNil(TempleArc.header(huge).flatMap { $0.expanded <= FileImport.MAX_FILE_BYTES ? $0 : nil })
        XCTAssertThrowsError(try TempleArc.expand(huge, limit: FileImport.MAX_FILE_BYTES), "oversized output is refused before allocation")
        // random corruption: refused, or exactly the declared size (never more, never a crash or hang)
        var seed: UInt64 = 0x5EED
        for _ in 0..<300 {
            var b = raw
            for _ in 0..<3 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; b[17 + Int(seed >> 33) % (b.count - 17)] ^= UInt8(truncatingIfNeeded: seed >> 7) | 1 }
            if let out = try? TempleArc.expand(b, limit: 1 << 20) { XCTAssertEqual(2775, out.count) }
        }
    }

    // ------------------------------------------------------------ the ZIP reader

    func testRealArchivesReadEntryForEntry() throws {
        let dir = tmp()
        for (name, files) in [("Sup1Snd.zip", ["Sup1Snd/", "Sup1Snd/SndFile.HC.Z", "Sup1Snd/MakeSnd.HC.Z", "Sup1Snd/SndMath.HC.Z", "Sup1Snd/SndMusic.HC.Z", "Sup1Snd/SndEffects.HC.Z"]),
                              ("SndSource.zip", ["SndSource/", "SndSource/SndFile.HC", "SndSource/SndMath.HC", "SndSource/SndMusic.HC", "SndSource/MakeSnd.HC", "SndSource/SndEffects.HC"])] {
            let u = dir.appendingPathComponent(name)
            try Data(fixture(name)).write(to: u)
            let z = try ZipArchive(u.path, maxEntries: 100)
            XCTAssertEqual(files, z.entries.map { String(decoding: $0.rawName, as: UTF8.self) })
            for e in z.entries where !e.isDir { XCTAssertEqual(e.size, try z.data(e).count) }
            z.close()
        }
    }

    func testMalformedContainersAreRefused() throws {
        let good = zip([ZEntry("A/One.HC", Array("\"one\\n\";\n".utf8), method: 8), ZEntry("A/Two.HC", Array(repeating: 65, count: 5000), method: 8)])
        XCTAssertNil(archiveKey([], bytes: good), "the reference archive imports")
        XCTAssertEqual("import.error.invalid_zip", archiveKey([], bytes: Array("not a zip at all, just text".utf8)))
        XCTAssertEqual("import.error.empty", archiveKey([], bytes: []))
        for n in [10, 21, good.count / 2, good.count - 1] {
            XCTAssertEqual("import.error.invalid_zip", archiveKey([], bytes: Array(good.prefix(n))) ?? "nil", "truncated to \(n)")
        }
        var badCrc = ZEntry("A/One.HC", Array(repeating: 66, count: 300), method: 8); badCrc.crc = 0x1234_5678
        XCTAssertEqual("import.error.damaged", archiveKey([badCrc]))
        var short = ZEntry("A/One.HC", Array(repeating: 67, count: 300), method: 8); short.size = 200
        XCTAssertEqual("import.error.damaged", archiveKey([short]), "inflates beyond its declared size")
        var long = ZEntry("A/One.HC", Array(repeating: 67, count: 300), method: 8); long.size = 400
        XCTAssertEqual("import.error.damaged", archiveKey([long]), "inflates to less than its declared size")
        var stored = ZEntry("A/One.HC", Array(repeating: 1, count: 50)); stored.csize = 40
        XCTAssertEqual("import.error.damaged", archiveKey([stored]), "stored sizes disagree")
        var garbage = ZEntry("A/One.HC", Array(repeating: 1, count: 50), method: 8); garbage.raw = [0xFF, 0xFE, 0xFD, 0x00, 0x13]
        XCTAssertEqual("import.error.damaged", archiveKey([garbage]), "not a Deflate stream")
        var renamed = ZEntry("A/One.HC", [1, 2, 3]); renamed.localName = Array("A/Evil.HC".utf8)
        XCTAssertEqual("import.error.invalid_zip", archiveKey([renamed]), "local header names another file")
        XCTAssertEqual("import.error.zip_unsupported", archiveKey([ZEntry("A.HC", [1])], bytes: zip([ZEntry("A.HC", [1])], eocdCount: 0xFFFF)))
        XCTAssertEqual("import.error.zip_unsupported", archiveKey([ZEntry("A.HC", [1])], bytes: zip([ZEntry("A.HC", [1])], disk: 1)))
        // two central entries pointing at the same data (an overlapping-file bomb)
        var twice = zip([ZEntry("A.HC", Array(repeating: 9, count: 100)), ZEntry("B.HC", Array(repeating: 9, count: 100))])
        let cd = twice.count - 22 - 2 * (46 + 4)
        twice[cd + 46 + 4 + 42] = 0; twice[cd + 46 + 4 + 43] = 0 // B's local offset := A's
        XCTAssertEqual("import.error.invalid_zip", archiveKey([], bytes: twice))
    }

    // ------------------------------------------------------------ archive policy (untrusted names and sizes)

    func testTraversalLinksAndUnsafeEntriesAreRefusedBeforeAnythingIsWritten() {
        for evil in ["../Evil.HC", "A/../../Evil.HC", "/Abs.HC", "C:/Kernel/Evil.HC", "A\\..\\..\\Evil.HC", "..\\Evil.HC", "A/./B.HC", "::/Evil.HC"] {
            XCTAssertEqual("import.error.unsafe_path", archiveKey([ZEntry("Good.HC", [1]), ZEntry(evil, [2])]), evil)
        }
        var link = ZEntry("A/Link.HC", Array("/etc/passwd".utf8)); link.external = 0o120777 << 16
        XCTAssertEqual("import.error.link", archiveKey([ZEntry("A/Ok.HC", [1]), link]))
        var fifo = ZEntry("A/Pipe", []); fifo.external = 0o010644 << 16
        XCTAssertEqual("import.error.link", archiveKey([fifo]))
        var enc = ZEntry("A/Secret.HC", [1, 2, 3]); enc.flags = 1
        XCTAssertEqual("import.error.encrypted", archiveKey([enc]))
        var lzma = ZEntry("A/X.HC", [1, 2, 3]); lzma.method = 14; lzma.raw = [1, 2, 3]
        XCTAssertEqual("import.error.method", archiveKey([lzma]))
        XCTAssertEqual("import.error.duplicate", archiveKey([ZEntry("A/Game.HC", [1]), ZEntry("A/GAME.hc", [2])]), "names differ only in case")
        XCTAssertEqual("import.error.duplicate", archiveKey([ZEntry("A/Song.HC", [1]), ZEntry("A/Song.HC.Z", TempleArc.store([2]))]), "X.HC and X.HC.Z are one file on C:")
        XCTAssertEqual("import.error.file_and_folder", archiveKey([ZEntry("A/B", [1]), ZEntry("A/B/C.HC", [2])]))
        XCTAssertEqual("import.error.file_and_folder", archiveKey([ZEntry("A/B/C.HC", [2]), ZEntry("A/B", [1])]))
        XCTAssertEqual("import.error.bad_name", archiveKey([ZEntry("A/\u{416}\u{416}.HC", [1])]), "not in the TempleOS character set")
        XCTAssertEqual("import.error.bad_name", archiveKey([ZEntry("A/" + String(repeating: "N", count: 36) + ".HC", [1])]), "longer than 38")
        XCTAssertEqual("import.error.bad_name", archiveKey([ZEntry("A/Bad*.HC", [1])]))
        XCTAssertEqual("import.error.bad_name", archiveKey([ZEntry("A/.tmp-hidden.HC", [1])]))
        XCTAssertEqual("import.error.bad_name", archiveKey([ZEntry("A//B.HC", [1])]))
        let deep = (1...9).map { "D\($0)" }.joined(separator: "/") + "/X.HC"
        XCTAssertEqual("import.error.too_deep", archiveKey([ZEntry(deep, [1])]))
        XCTAssertNil(archiveKey([ZEntry((1...8).map { "D\($0)" }.joined(separator: "/") + "/X.HC", [1])]), "eight folders are allowed")
        XCTAssertEqual("import.error.corrupt_z_entry", archiveKey([ZEntry("A/Bad.HC.Z", Array("plain text, not compressed".utf8))]))
        XCTAssertEqual("import.error.empty_archive", archiveKey([ZEntry("A/", []), ZEntry("__MACOSX/A/._X.HC", [0, 5, 22])]))
    }

    func testResourceLimitsStopZipBombsBeforeExtraction() {
        // a declared size over the per-file limit is refused from the central directory alone
        var big = ZEntry("A/Big.BIN", [0]); big.size = FileImport.MAX_FILE_BYTES + 1; big.crc = 0
        XCTAssertEqual("import.error.entry_too_large", archiveKey([big]))
        // 2 MiB of zeros deflate to about 2 KiB: a ratio no TempleOS program has
        XCTAssertEqual("import.error.ratio", archiveKey([ZEntry("A/Bomb.BIN", [UInt8](repeating: 0, count: 2 << 20), method: 8)]))
        // forged sizes: four entries declaring 13 MiB each at an ordinary ratio
        let forged = (0..<4).map { i -> ZEntry in var e = ZEntry("A/Part\(i).BIN", [UInt8](repeating: UInt8(i), count: 100_000)); e.size = 13 << 20; return e }
        XCTAssertEqual("import.error.expands_too_large", archiveKey(forged))
        XCTAssertEqual("import.error.too_many_entries", archiveKey((0...FileImport.MAX_ENTRIES).map { ZEntry("A/F\($0).HC", [1]) }))
        // TempleOS compression inside an archive is bounded by its declared size too
        var hc = TempleArc.store(Array("Hi".utf8)); hc[8] = 0; hc[9] = 0; hc[10] = 0; hc[11] = 0x10 // declares 256 MiB
        XCTAssertEqual("import.error.entry_too_large", archiveKey([ZEntry("A/Huge.HC.Z", hc)]))
        let dir = tmp(), fs = drive(dir)
        let r = FileImport.prepare(fs, picked("Big.zip", [UInt8](repeating: 0, count: FileImport.MAX_ARCHIVE_BYTES + 1)))
        XCTAssertEqual("import.error.archive_too_large", key(r))
    }

    // ------------------------------------------------------------ single files

    func testSourceAndCompressedSourceLandOnTheDriveByteForByte() throws {
        let dir = tmp(), fs = drive(dir)
        let copy = picked("DiningStars.HC", fixture("DiningStars.HC"))
        XCTAssertEqual("C:/Home/Imports/DiningStars.HC", try importNow(fs, copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.hostPath!), "the platform's copy is deleted")
        XCTAssertEqual("559504014bb2fb4b6a0554f376bedb1640c254981eb4a1dfa07d180f8b70a8a7", sha(fs.readFile("C:/Home/Imports/DiningStars.HC")!))
        // .HC.Z is expanded and stored under its name without .Z, as the bundled drive stores the ISO's files
        XCTAssertEqual("C:/Home/Imports/o.HC", try importNow(fs, picked("o.HC.Z", fixture("o.HC.Z"))))
        XCTAssertEqual("e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", sha(fs.readFile("C:/Home/Imports/o.HC")!))
        XCTAssertEqual(fs.readFile("C:/Home/Imports/o.HC"), fs.readFile("C:/Home/Imports/o.HC.Z"), "the .Z name resolves to it")
        XCTAssertEqual(["DiningStars.HC", "o.HC"], fs.list("C:/Home/Imports")!.map { $0.name }.sorted())
        XCTAssertTrue(fs.list("C:/Home")!.contains { $0.name == "Imports" && $0.isDir }, "Files shows the folder in the home folder")
        XCTAssertEqual([], leftovers(dir))
        // persistent: a new drive over the same storage (the next launch) sees the same files
        XCTAssertEqual(fs.readFile("C:/Home/Imports/o.HC"), drive(dir).readFile("C:/Home/Imports/o.HC"))
    }

    func testMislabelledEmptyAndUnrepresentableFilesAreRefused() {
        let dir = tmp(), fs = drive(dir)
        func k(_ name: String, _ b: [UInt8]) -> String? { let r = FileImport.prepare(fs, picked(name, b)); FileImport.discard(fs, r); return key(r) }
        XCTAssertEqual("import.error.is_zip", k("Game.HC", fixture("Sup1Snd.zip")))
        XCTAssertEqual("import.error.is_compressed", k("o.HC", fixture("o.HC.Z")), "a renamed .HC.Z")
        XCTAssertEqual("import.error.corrupt_z", k("Fake.HC.Z", Array("U0 Main() {}\n".utf8)), "a renamed .HC is not TempleOS-compressed")
        XCTAssertEqual("import.error.invalid_zip", k("Fake.zip", fixture("DiningStars.HC")))
        XCTAssertEqual("import.error.empty", k("Empty.HC", []))
        XCTAssertEqual("import.error.unsupported_type", k("Notes.TXT", Array("text".utf8)))
        XCTAssertEqual("import.error.bad_name", k("\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}.HC", Array("1;".utf8)), "Cyrillic is not in the TempleOS character set")
        XCTAssertEqual("import.error.bad_name", k(String(repeating: "L", count: 40) + ".HC", Array("1;".utf8)))
        XCTAssertEqual("import.error.too_large", k("Huge.HC", [UInt8](repeating: 32, count: FileImport.MAX_FILE_BYTES + 1)))
        XCTAssertEqual("import.error.read", key(FileImport.prepare(fs, PickedFile(name: "Gone.HC", hostPath: "/nonexistent/x"))))
        XCTAssertEqual("import.error.device_storage", key(FileImport.prepare(fs, PickedFile(name: "A.HC", hostPath: nil, problem: ImportError("import.error.device_storage")))))
        // Latin-1 and CP437 names are fine, also in decomposed (NFD) form as some providers report them
        XCTAssertNil(k("Cafe\u{301}.HC", Array("1;".utf8)))
        XCTAssertNotNil(FileImport.driveName("\u{C9}t\u{E9}.HC"))
        XCTAssertEqual([], leftovers(dir))
        XCTAssertFalse(fs.exists("C:/Home/Imports"), "nothing was published")
    }

    // ------------------------------------------------------------ archives

    func testArchivesKeepTheirFoldersAndExpandTempleOSCompressedFiles() throws {
        let dir = tmp(), fs = drive(dir)
        XCTAssertEqual("C:/Home/Imports/Sup1Snd", try importNow(fs, picked("Sup1Snd.zip", fixture("Sup1Snd.zip"))))
        let expected = ["MakeSnd.HC": "18950622af5eedf236666ddf4ad8d76f30ce49d8b5068dcacbdf1b26d40686de",
                        "SndMath.HC": "f0d7ba7625624b960e2d179ceee6e240a8b6455ac65aabd273c84b59f1fd53a3",
                        "SndMusic.HC": "b44d52a3e85e615a6b44a5d26adc4cd9325867e1ae8a164a4ad68942e6185166",
                        "SndEffects.HC": "21d771ef71014645afa97df850fc7b3417d0e982a6ceb96055eb7d802f27f09f",
                        "SndFile.HC": "d3efc36170b9e2a190eff94395e7e49d58fc8f6b436def2f14cb81b112d9940b"]
        XCTAssertEqual(expected.keys.sorted(), fs.list("C:/Home/Imports/Sup1Snd")!.map { $0.name }.sorted())
        for (n, d) in expected { XCTAssertEqual(d, sha(fs.readFile("C:/Home/Imports/Sup1Snd/" + n)!), n) }
        // Finder's format (Deflate, data descriptors): the same sources, plain
        XCTAssertEqual("C:/Home/Imports/SndSource", try importNow(fs, picked("SndSource.zip", fixture("SndSource.zip"))))
        for (n, d) in expected { XCTAssertEqual(d, sha(fs.readFile("C:/Home/Imports/SndSource/" + n)!), n) }
        // no single top folder: a folder named after the archive; binary files, empty folders and nesting kept;
        // Finder's metadata is not content
        let bin = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) }
        let mixed = zip([ZEntry("Main.HC", Array("#include \"Lib/Util\"\n".utf8), method: 8), ZEntry("Lib/Util.HC", Array("U0 Util() {}\n".utf8)),
                         ZEntry("Assets/Sprite.BIN", bin, method: 8), ZEntry("Assets/Empty/", []), ZEntry("Readme.TXT", Array("hello".utf8)),
                         ZEntry("__MACOSX/._Main.HC", [0, 5, 22, 7]), ZEntry(".DS_Store", [0, 0, 0, 1]),
                         ZEntry("Caf\u{E9}.HC", Array("1;".utf8))])
        XCTAssertEqual("C:/Home/Imports/MyGame", try importNow(fs, picked("MyGame.zip", mixed)))
        XCTAssertEqual(bin, fs.readFile("C:/Home/Imports/MyGame/Assets/Sprite.BIN"))
        XCTAssertTrue(fs.isDir("C:/Home/Imports/MyGame/Assets/Empty"))
        XCTAssertEqual(["Assets", "Caf\u{82}.HC", "Lib", "Main.HC", "Readme.TXT"], fs.list("C:/Home/Imports/MyGame")!.map { $0.name }.sorted(),
                       "a UTF-8 name is stored as TempleOS (CP437) bytes; no metadata files")
        XCTAssertEqual([], leftovers(dir))
    }

    // ------------------------------------------------------------ the drive: collisions, quota, recovery

    func testCollisionsNeverOverwriteSilentlyAndBundledFilesAreProtected() throws {
        let dir = tmp(), fs = drive(dir)
        try importNow(fs, picked("o.HC.Z", fixture("o.HC.Z")))
        let again = FileImport.prepare(fs, picked("o.HC", Array("\"mine\\n\";\n".utf8)))
        XCTAssertThrowsError(try FileImport.publish(fs, again, as: again.name, replace: false), "a taken name is an error unless replacing")
        XCTAssertEqual("o_2.HC", FileImport.freeName(fs, again.name))
        try FileImport.publish(fs, again, as: "o_2.HC", replace: false)
        FileImport.discard(fs, again)
        XCTAssertEqual("o_3.HC", FileImport.freeName(fs, "o.HC"))
        // Replace: the new content, atomically, and the replaced bytes are given back
        let before = fs.usedBytes()
        let rep = FileImport.prepare(fs, picked("o.HC", Array("\"replaced\\n\";\n".utf8)))
        try FileImport.publish(fs, rep, as: "o.HC", replace: true)
        FileImport.discard(fs, rep)
        XCTAssertEqual(Array("\"replaced\\n\";\n".utf8), fs.readFile("C:/Home/Imports/o.HC"))
        XCTAssertEqual(before - 437 + 14, fs.usedBytes())
        // folders replace as a whole
        try importNow(fs, picked("Sup1Snd.zip", fixture("Sup1Snd.zip")))
        let folder = FileImport.prepare(fs, picked("Sup1Snd.zip", zip([ZEntry("Sup1Snd/Only.HC", [65])])))
        try FileImport.publish(fs, folder, as: folder.name, replace: true)
        FileImport.discard(fs, folder)
        XCTAssertEqual(["Only.HC"], fs.list("C:/Home/Imports/Sup1Snd")!.map { $0.name })
        // a bundled original is never replaced, whatever is asked
        let stage = try fs.beginStage()
        try fs.stageFile(stage, "Maze.HC", [1, 2, 3])
        XCTAssertThrowsError(try fs.publishStaged(stage, "Maze.HC", "C:/Demo/Games/Maze.HC", replace: true))
        fs.discardStage(stage)
        XCTAssertNotEqual([1, 2, 3], fs.readFile("C:/Demo/Games/Maze.HC"))
        XCTAssertEqual(38, FileImport.freeName(fs, String(repeating: "N", count: 35) + ".HC")!.count, "long names are shortened to fit")
        XCTAssertEqual([], leftovers(dir))
    }

    func testTheQuotaAppliesAndAFailedImportGivesEverythingBack() {
        let dir = tmp(), fs = drive(dir, quota: 1 << 20)
        let used = fs.usedBytes()
        let r = FileImport.prepare(fs, picked("Big.zip", zip([ZEntry("Big/A.BIN", [UInt8](repeating: 1, count: 700_000)),
                                                              ZEntry("Big/B.BIN", [UInt8](repeating: 2, count: 700_000))])))
        XCTAssertEqual("fs.error.storage_full", key(r))
        XCTAssertEqual(used, fs.usedBytes())
        XCTAssertEqual([], leftovers(dir))
        XCTAssertFalse(fs.exists("C:/Home/Imports/Big"))
    }

    func testAnInterruptedImportIsUndoneOnTheNextStart() throws {
        let dir = tmp(), fs = drive(dir)
        try importNow(fs, picked("o.HC.Z", fixture("o.HC.Z")))
        // killed while staging: the staging folder is removed at the next start
        let s = try fs.beginStage()
        try fs.stageFile(s, "Half/One.HC", [1])
        XCTAssertEqual(1, leftovers(dir).count)
        _ = drive(dir)
        XCTAssertEqual([], leftovers(dir))
        // killed between moving the replaced file aside and renaming the new one into place
        let files = dir.appendingPathComponent("drive/files")
        let stage = files.appendingPathComponent(".tmp-import-crash")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: files.appendingPathComponent("Home/Imports/o.HC"), to: stage.appendingPathComponent(".replaced-1"))
        try Data(".tmp-import-crash/.replaced-1\tHome/Imports/o.HC".utf8).write(to: dir.appendingPathComponent("drive/import-journal.txt"))
        let after = drive(dir)
        XCTAssertEqual("e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", sha(after.readFile("C:/Home/Imports/o.HC") ?? []), "the earlier file is back")
        XCTAssertEqual([], leftovers(dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("drive/import-journal.txt").path))
        XCTAssertEqual(after.usedBytes(), Int64(437))
    }

    // ------------------------------------------------------------ the flow, through the real shell

    private final class Run {
        let sh: Shell, env: HeadlessEnv
        var t: Int64 = 1000
        var picks = 0
        init(_ dir: URL) {
            env = HeadlessEnv(dir)
            sh = Shell(env)
            sh.resize(402, 874, 62, 34, 0, 0, 0)
            _ = sh.tick()
            env.picker = { [unowned self] in picks += 1; return true }
        }
        @discardableResult func waitFor(_ s: Double, _ c: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(s)
            while Date() < end { _ = sh.tick(); if c() { return true }; Thread.sleep(forTimeInterval: 0.016) }
            _ = sh.tick(); return c()
        }
        func labels() -> [String] { _ = sh.tick(); return sh.accessibilityNodes().map { $0.label } }
        func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            _ = sh.tick()
            guard let r = sh.accessibilityNodes().first(where: { $0.label == label })?.rect else {
                XCTFail("no '\(label)' in \(labels())", file: file, line: line); return
            }
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: 1, timeMs: t)); t += 50
            sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: 1, timeMs: t)); t += 50
            _ = sh.tick()
        }
        func importFiles(_ files: [PickedFile]) {
            sh.importFlow.receive(files)
            XCTAssertTrue(waitFor(20) { !sh.importFlow.busy && sh.dialogOpen }, "the summary appears")
        }
        func close() { sh.windows.forEach { sh.close($0, force: true) } }
    }

    func testImportFromTheStartMenuWithTheFirstTimeExplanation() throws {
        let dir = tmp(), r = Run(dir)
        defer { r.close() }
        r.tap(tr("topbar.menu"))
        XCTAssertTrue(r.labels().contains(tr("menu.start.import")), "the start menu has Import...")
        r.tap(tr("menu.start.import"))
        XCTAssertTrue(r.sh.dialogOpen, "the explanation comes first")
        XCTAssertTrue(r.labels().contains(tr("import.intro.title")))
        XCTAssertEqual(0, r.picks, "no picker before the explanation")
        r.tap(tr("button.cancel"))
        XCTAssertFalse(r.sh.dialogOpen); XCTAssertFalse(r.sh.settings.importIntroSeen, "Cancel does not count as seen")
        XCTAssertEqual(0, r.picks)
        r.tap(tr("topbar.menu")); r.tap(tr("menu.start.import"))
        XCTAssertTrue(r.labels().contains(tr("import.intro.title")), "shown again after Cancel")
        r.tap(tr("button.choose_files"))
        XCTAssertTrue(r.waitFor(2) { r.picks == 1 }, "the picker opens")
        XCTAssertTrue(r.sh.settings.importIntroSeen)
        XCTAssertTrue(r.env.session?.contains(";i=1") == true, "persisted with the session")
        // repeated taps while the picker is open never open a second one
        r.sh.importFlow.start(); r.sh.importFlow.start()
        XCTAssertEqual(1, r.picks)
        // the picker returns a genuine external .HC.Z
        r.importFiles([picked("o.HC.Z", fixture("o.HC.Z"))])
        XCTAssertTrue(r.labels().contains(tr("import.done.title")))
        XCTAssertTrue(r.labels().contains(tr("button.run")), "Run is offered for one program, never automatic")
        XCTAssertFalse(r.sh.windows.contains { $0.app.kind == "program" }, "nothing ran by itself")
        r.tap(tr("button.open_folder"))
        XCTAssertTrue(r.waitFor(2) { (r.sh.focused?.app as? FilesApp)?.dir == "C:/Home/Imports" }, "Open Folder shows the import in Files")
        // in Files, like any file: tap, Run (the normal launcher, the HolyC interpreter)
        r.tap(tr("files.a11y.file_item", ("name", "o.HC"), ("size", 437)))
        r.tap(tr("files.menu.run"))
        let p = try XCTUnwrap(r.sh.focused?.app as? ProgramApp)
        XCTAssertEqual("C:/Home/Imports/o.HC", p.path)
        XCTAssertTrue(r.waitFor(30) { p.kernel.speakerChanges >= 20 }, "the hymn plays: \(p.kernel.speakerChanges) speaker changes")
        XCTAssertFalse(p.isFinished)
        let (ch, sc) = Keys.forChar(32)
        r.sh.key(ch, sc, true); r.sh.key(ch, sc | Keys.SCF_KEY_UP, false)
        XCTAssertTrue(r.waitFor(60) { p.kernel.finished }, "a key ends it (ScanKey, checked after each pass of the song)")
        XCTAssertEqual(ExitCategory.NORMAL, p.kernel.exitCategory)
        // later imports skip the explanation
        r.tap(tr("topbar.menu")); r.tap(tr("menu.start.import"))
        XCTAssertEqual(2, r.picks); XCTAssertFalse(r.labels().contains(tr("import.intro.title")))
        // the same name again: Keep Both, then Replace, then Cancel
        r.sh.importFlow.receive([])
        XCTAssertTrue(r.waitFor(2) { !r.sh.importFlow.busy }, "a cancelled picker ends the import")
        r.sh.importFlow.receive([picked("o.HC.Z", fixture("o.HC.Z"))])
        XCTAssertTrue(r.waitFor(20) { r.labels().contains(tr("button.keep_both")) }, "asked, not overwritten")
        r.tap(tr("button.keep_both"))
        XCTAssertTrue(r.waitFor(10) { r.labels().contains(tr("import.done.title")) })
        XCTAssertTrue(r.sh.fs.exists("C:/Home/Imports/o_2.HC"))
        r.tap(tr("button.close"))
        r.sh.importFlow.receive([picked("o.HC", Array("\"new\\n\";\n".utf8))])
        XCTAssertTrue(r.waitFor(20) { r.labels().contains(tr("button.replace")) })
        r.tap(tr("button.replace"))
        XCTAssertTrue(r.waitFor(10) { r.labels().contains(tr("import.done.title")) })
        XCTAssertEqual(Array("\"new\\n\";\n".utf8), r.sh.fs.readFile("C:/Home/Imports/o.HC"))
        r.tap(tr("button.close"))
        r.sh.importFlow.receive([picked("o.HC", Array("\"other\\n\";\n".utf8))])
        XCTAssertTrue(r.waitFor(20) { r.labels().contains(tr("button.replace")) })
        r.tap(tr("button.cancel"))
        XCTAssertTrue(r.waitFor(5) { !r.sh.importFlow.busy })
        XCTAssertEqual(Array("\"new\\n\";\n".utf8), r.sh.fs.readFile("C:/Home/Imports/o.HC"), "Cancel keeps the earlier file")
        XCTAssertTrue(r.waitFor(2) { leftovers(dir, "files").isEmpty }, "staging folders are deleted")
    }

    func testFailuresAreReportedAndTheAppStaysUsable() throws {
        let dir = tmp(), r = Run(dir)
        defer { r.close() }
        r.importFiles([picked("Bad.zip", zip([ZEntry("../Evil.HC", [1])])), picked("Notes.TXT", [1]), picked("o.HC.Z", fixture("o.HC.Z"))])
        let text = r.labels().joined(separator: "\n")
        XCTAssertTrue(text.contains(tr("import.partial.title")), text)
        XCTAssertTrue(text.contains(tr("import.result.failed", ("name", "Bad.zip"), ("reason", tr("import.error.unsafe_path", ("entry", "../Evil.HC"))))), text)
        XCTAssertTrue(text.contains(tr("import.error.unsupported_type")), text)
        XCTAssertTrue(r.labels().contains(tr("button.run")), "one program was imported: Run is offered")
        XCTAssertFalse(r.sh.windows.contains { $0.app.kind == "program" }, "and nothing ran by itself")
        r.tap(tr("button.close"))
        r.importFiles([picked("Only.TXT", [1])])
        XCTAssertTrue(r.labels().contains(tr("import.failed.title")))
        XCTAssertFalse(r.labels().contains(tr("button.open_folder")))
        r.tap(tr("button.close"))
        XCTAssertTrue(r.waitFor(2) { leftovers(dir, "files").isEmpty })
        // a program dialog open when the result arrives: the summary waits, the program's dialog is left alone
        r.sh.showDialog(Dialog.confirm("Program", "A program's question", "OK") {})
        r.sh.importFlow.receive([picked("B17.HC.Z", fixture("B17.HC.Z"))])
        Thread.sleep(forTimeInterval: 1.0); _ = r.sh.tick()
        XCTAssertTrue(r.labels().contains("A program's question"), "not replaced by the import's summary")
        _ = r.sh.back()
        XCTAssertTrue(r.waitFor(5) { r.labels().contains(tr("import.done.title")) }, "the summary follows")
    }

    // ------------------------------------------------------------ genuine external programs on the interpreter

    private func closeApp(_ r: Run, _ app: App) { if let w = r.sh.windows.first(where: { $0.app === app }) { r.sh.close(w, force: true) } }

    /** Opens [path] from Files (tap, Run), the way a user runs any file. */
    private func runFromFiles(_ r: Run, _ path: String) throws -> ProgramApp {
        Launch.files(r.sh, Paths.parent(path))
        let entry = try XCTUnwrap(r.sh.fs.stat(path), path)
        r.tap(tr("files.a11y.file_item", ("name", Paths.name(path)), ("size", entry.size)))
        r.tap(tr("files.menu.run"))
        return try XCTUnwrap(r.sh.focused?.app as? ProgramApp, path)
    }

    func testGenuineExternalProgramsRunFromFilesAndAfterARestart() throws {
        let dir = tmp()
        var r = Run(dir)
        r.importFiles([picked("DiningStars.HC", fixture("DiningStars.HC")), picked("B17.HC.Z", fixture("B17.HC.Z")),
                       picked("Span.zip", fixture("Span.zip")), picked("Sup1Snd.zip", fixture("Sup1Snd.zip")), picked("NewOS.HC.Z", fixture("NewOS.HC.Z"))])
        XCTAssertTrue(r.labels().contains(tr("import.done.title")), r.labels().joined(separator: " | "))
        r.tap(tr("button.close"))
        // Test A: a plain external .HC prints its instructions and draws
        let dining = try runFromFiles(r, "C:/Home/Imports/DiningStars.HC")
        XCTAssertTrue(r.waitFor(30) { dining.kernel.console.plainText().contains("Draw Floor Plan") && dining.kernel.graphicsUsed }, dining.kernel.console.plainText())
        XCTAssertNil(dining.kernel.exitCategory)
        closeApp(r, dining)
        // Test B: an 8-bit-LZW .HC.Z with DolDoc sprites runs its animation
        let b17 = try runFromFiles(r, "C:/Home/Imports/B17.HC")
        XCTAssertTrue(r.waitFor(30) { b17.kernel.graphicsUsed && b17.kernel.frameCount >= 10 }, "B17 draws")
        closeApp(r, b17)
        // Test C: a program in folders from an archive of TempleOS-compressed files: Run.HC includes Load.HC, which
        // includes Span.HH and four .HC siblings (Cd(__DIR__) and relative #include), all from C:/Home/Imports/Span
        XCTAssertEqual(["Install.HC", "Load.HC", "Run.HC", "Span.HH", "SpanBridge.HC", "SpanDerive.HC", "SpanMain.HC", "SpanNew.HC"],
                       r.sh.fs.list("C:/Home/Imports/Span")!.map { $0.name }.sorted())
        let span = try runFromFiles(r, "C:/Home/Imports/Span/Run.HC")
        XCTAssertTrue(r.waitFor(30) { span.kernel.graphicsUsed && span.kernel.frameCount >= 10 }, span.kernel.console.plainText())
        XCTAssertNil(span.kernel.exitCategory, span.kernel.console.plainText())
        for sym in ["Span", "SpanBridge1Init", "MyDerivative", "SpanDel"] where span.kernel.prog.globals[sym] == nil { XCTFail("\(sym) not compiled from a sibling") }
        closeApp(r, span)
        // Test D: genuine programs that need what the interpreter does not have: imported fine, a clear message, app usable.
        // MakeSnd.HC's siblings resolve (three compile) until SndFile.HC uses HD Audio's `snd`
        let snd = try runFromFiles(r, "C:/Home/Imports/Sup1Snd/MakeSnd.HC")
        XCTAssertTrue(r.waitFor(30) { snd.kernel.finished }, snd.kernel.console.plainText())
        XCTAssertEqual(ExitCategory.COMPILE_ERROR, snd.kernel.exitCategory)
        XCTAssertTrue(snd.kernel.console.plainText().contains("C:/Home/Imports/Sup1Snd/SndFile.HC:33: undefined identifier 'snd'"), snd.kernel.console.plainText())
        closeApp(r, snd)
        let newOS = try runFromFiles(r, "C:/Home/Imports/NewOS.HC")
        XCTAssertTrue(r.waitFor(30) { newOS.kernel.finished })
        XCTAssertEqual(ExitCategory.COMPILE_ERROR, newOS.kernel.exitCategory)
        XCTAssertTrue(newOS.kernel.console.plainText().contains("inline x86 assembly"), newOS.kernel.console.plainText())
        r.close()
        // restart: a new shell over the same storage finds and runs them again
        r = Run(dir)
        defer { r.close() }
        XCTAssertEqual(["B17.HC", "DiningStars.HC", "NewOS.HC", "Span", "Sup1Snd"], r.sh.fs.list("C:/Home/Imports")!.map { $0.name }.sorted())
        let again = try runFromFiles(r, "C:/Home/Imports/B17.HC")
        XCTAssertTrue(r.waitFor(30) { again.kernel.graphicsUsed && again.kernel.frameCount >= 10 }, "B17 after a restart")
    }

    func testAnEndlessImportedProgramCanBeStopped() throws {
        let dir = tmp(), r = Run(dir)
        defer { r.close() }
        r.importFiles([picked("Spin.HC", Array("I64 i=0;\nwhile (TRUE) i++;\n".utf8))])
        r.tap(tr("button.run"))
        let p = try XCTUnwrap(r.sh.focused?.app as? ProgramApp)
        Thread.sleep(forTimeInterval: 1.0); _ = r.sh.tick()
        XCTAssertFalse(p.isFinished, "still spinning")
        let w = try XCTUnwrap(r.sh.windows.first { $0.app === p })
        r.sh.close(w, force: true)
        XCTAssertTrue(r.waitFor(5) { p.isFinished }, "closing the window stops the interpreter")
        Launch.terminal(r.sh); XCTAssertEqual("terminal", r.sh.focused?.app.kind, "the app is usable afterwards")
    }
}
