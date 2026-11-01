import CryptoKit
import Foundation
import XCTest
@testable import TempleCore

/** Hex sha256 of [b] (tests that identify original wording by hash instead of spelling it out). */
func sha256Hex(_ b: [UInt8]) -> String { SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined() }

/**
 * Content moderation of the bundled TempleOS files (docs/content-moderation/CONTENT_MODERATION.md;
 * Kotlin ContentModerationTest). The edits are made when the bundled drive is built
 * (tools/resource-packaging/moderation.json); these tests check what the apps actually show. The
 * original wording is never written here: it is identified by the manifest's hashes, and checks that
 * need it rebuild it in memory from the ISO extraction (reference/templeos-iso, on development machines).
 */
final class ContentModerationTests: XCTestCase {
    private var dir: URL!
    private var env: HeadlessEnv!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("moderation-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env = HeadlessEnv(dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private struct Edit { let id: String, path: String, line: Int, start: Int, end: Int, sha256: String, replace: String, scope: String }

    private static let manifest: (markers: [String: String], edits: [Edit]) = {
        let url = SHARED.deletingLastPathComponent().appendingPathComponent("tools/resource-packaging/moderation.json")
        let m = try! Json.parse(String(decoding: readFileBytes(url)!, as: UTF8.self)) as! [String: Any?]
        let markers = (m["markers"] as! [String: Any?]).mapValues { $0 as! String }
        let edits = (m["edits"] as! [Any?]).map { e -> Edit in
            let d = e as! [String: Any?]
            func i(_ k: String) -> Int { Int(truncating: d[k] as! NSNumber) }
            return Edit(id: d["id"] as! String, path: d["path"] as! String, line: i("line"), start: i("start"), end: i("end"),
                        sha256: d["sha256"] as! String, replace: d["replace"] as! String, scope: d["scope"] as! String)
        }
        return (markers, edits)
    }()

    private func replacement(_ e: Edit) -> String { e.replace.hasPrefix("@") ? Self.manifest.markers[String(e.replace.dropFirst())]! : e.replace }

    /** Lines of the text part (before the first NUL) of bundled or ISO bytes. */
    private func lines(_ b: [UInt8]) -> [[UInt8]] {
        let text = b.firstIndex(of: 0).map { Array(b[..<$0]) } ?? b
        return text.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
    }

    private func bundled(_ path: String) -> [UInt8] { env.fs.readFile("C:/\(path)")! }
    private func iso(_ path: String) -> [UInt8]? { readFileBytes(REFERENCE.appendingPathComponent("templeos-iso/\(path)")) }

    /** The index: path -> origin. */
    private lazy var origins: [String: String] = {
        var o: [String: String] = [:]
        for l in String(decoding: readFileBytes(SHARED.appendingPathComponent("bundled-fs.index"))!, as: UTF8.self).split(separator: "\n") {
            let f = l.split(separator: "\t", omittingEmptySubsequences: false)
            if f.count >= 5 && f[0] == "F" { o[String(f[1])] = String(f[4]) }
        }
        return o
    }()

    private static let terry = "TempleOS V5.03 (public domain, Terry A. Davis)"

    /** Every manifest edit is in the shipped file, at its place, with its marker or replacement. */
    func testEveryEditIsInTheBundledFiles() {
        XCTAssertGreaterThanOrEqual(Self.manifest.edits.count, 20)
        for e in Self.manifest.edits {
            let ln = lines(bundled(e.path))[e.line - 1]
            let r = Array(replacement(e).utf8)
            // earlier edits on the same line moved this one by their change in length
            let shift = Self.manifest.edits.filter { $0.path == e.path && $0.line == e.line && $0.start < e.start }
                .reduce(0) { $0 + replacement($1).utf8.count - ($1.end - $1.start) }
            let at = e.start + shift
            XCTAssertEqual(Array(ln[at..<min(ln.count, at + r.count)]), r, "\(e.id): replacement in place")
            XCTAssertTrue(origins[e.path]!.hasPrefix(Self.terry + "; modified:"), "\(e.id): the index marks \(e.path) modified")
            XCTAssertEqual(DocProvenance.of(env.fs, "C:/\(e.path)"), .ADAPTED, "\(e.id): the viewer says adapted")
        }
        // and only those files are modified
        let edited = Set(Self.manifest.edits.map(\.path))
        for (path, origin) in origins where origin.contains("; modified:") { XCTAssertTrue(edited.contains(path), "\(path) modified without an edit") }
    }

    /** With the ISO extraction: each shipped file is exactly the original with the edits, nothing else. */
    func testOnlyTheManifestEditsDifferFromTheOriginals() throws {
        guard iso("Adam/God/HSNotes.DD") != nil else { throw XCTSkip("reference/templeos-iso is not on this machine") }
        for (path, origin) in origins where origin.hasPrefix(Self.terry) {
            let o = iso(path)!, b = bundled(path)
            let edits = Self.manifest.edits.filter { $0.path == path }
            if edits.isEmpty { XCTAssertEqual(o, b, "\(path) is byte-identical to the ISO"); continue }
            var ol = lines(o)
            for e in edits.sorted(by: { ($0.line, $0.start) > ($1.line, $1.start) }) {
                XCTAssertEqual(sha256Hex(Array(ol[e.line - 1][e.start..<e.end])), e.sha256, "\(e.id): the manifest matches the original")
                ol[e.line - 1].replaceSubrange(e.start..<e.end, with: Array(replacement(e).utf8))
            }
            XCTAssertEqual(lines(b), ol, "\(path): the original with the edits, every other line unchanged")
            // the binary part (sprites) is untouched
            if let i = o.firstIndex(of: 0) { XCTAssertEqual(Array(o[i...]), Array(b[b.firstIndex(of: 0)!...]), "\(path): sprites") }
        }
    }

    /** With the ISO extraction: no redacted wording reaches the screen, in the viewer's text or its accessibility labels. */
    func testRedactedWordingIsNotShownAnywhere() throws {
        guard iso("Adam/God/HSNotes.DD") != nil else { throw XCTSkip("reference/templeos-iso is not on this machine") }
        let sh = Shell(env); sh.resize(402, 874)
        for path in Set(Self.manifest.edits.filter { $0.path.hasSuffix(".DD") }.map(\.path)) {
            Launch.doc(sh, "C:/\(path)")
            for _ in 0..<3 { sh.invalidate(); _ = sh.tick() }
            let d = sh.focused!.app as! DocViewerApp
            let shown = d.documentText(200) + "\n" + sh.accessibilityNodes().map(\.label).joined(separator: "\n")
            let squashed = shown.filter { !$0.isWhitespace }
            for e in Self.manifest.edits where e.path == path && e.end - e.start >= 6 {
                let original = String(decoding: Array(lines(iso(path)!)[e.line - 1][e.start..<e.end]), as: UTF8.self)
                // the prose of the span without DolDoc commands, compared without whitespace (the viewer wraps lines)
                let prose = original.replacingOccurrences(of: #"\$[^$]*\$"#, with: "", options: .regularExpression).filter { !$0.isWhitespace }
                if prose.count >= 6 { XCTAssertFalse(squashed.contains(prose), "\(e.id): redacted wording is shown") }
            }
            XCTAssertTrue(shown.contains("redacted]"), "\(path): the marker is shown")
            sh.close(sh.focused!, force: true)
        }
    }

    /** Religious and technical content is not removed: the oracle instructions, scripture links, the Bible. */
    func testReligiousAndTechnicalTextIsKept() {
        let hs = String(decoding: bundled("Adam/God/HSNotes.DD"), as: UTF8.self)
        XCTAssertGreaterThan(hs.components(separatedBy: "God").count, 60, "God is everywhere in the Holy Spirit notes")
        for kept in ["Matthew,15:11", "1 Corinthians,12:1-31", "Numbers,11:1-35", "Are you calling me lazy?", "Favorite sport?", "Hockey"] {
            XCTAssertTrue(hs.contains(kept), "kept: \(kept)")
        }
        XCTAssertEqual(DocProvenance.of(env.fs, "C:/Misc/Bible.TXT"), .INCLUDED)
        XCTAssertTrue(String(decoding: bundled("Misc/Bible.TXT"), as: UTF8.self).contains("In the beginning God created the heaven and the earth."))
        // the Bible and the God Words list are not moderated beyond the one documented word
        XCTAssertFalse(Self.manifest.edits.contains { $0.path == "Misc/Bible.TXT" })
        XCTAssertEqual(1, Self.manifest.edits.filter { $0.path == "Adam/God/Vocab.DD" }.count)
    }

    /** Edits are located spans, not a word filter: words that merely contain a sensitive substring stay. */
    func testNoSubstringCollateral() {
        let all = ["Doc/Glossary.DD", "Doc/HolyC.DD", "Misc/PCIDevices.DD", "Doc/Charter.DD"].map { String(decoding: bundled($0), as: UTF8.self) }.joined()
        for w in ["class", "assembl", "Matsushita", "brainf***"] { XCTAssertTrue(all.contains(w), "\(w) present") }
        let hs = String(decoding: bundled("Adam/God/HSNotes.DD"), as: UTF8.self)
        XCTAssertTrue(hs.contains("Homosexuality?"), "a question that is not itself derogatory stays (editorial note in the report)")
    }

    /** Markers are plain DolDoc text: ASCII, no "$" (command delimiter), no NUL; the documents still parse. */
    func testMarkersAreSafeDolDocText() {
        for (_, m) in Self.manifest.markers {
            XCTAssertTrue(m.allSatisfy { $0.isASCII } && !m.contains("$") && !m.contains("\0"), m)
        }
        for path in Set(Self.manifest.edits.map(\.path)) {
            for (i, l) in lines(bundled(path)).enumerated() {
                // every line keeps its commands balanced: an even number of single "$" (a "$$" is a literal "$")
                let singles = String(decoding: l, as: UTF8.self).replacingOccurrences(of: "$$", with: "").filter { $0 == "$" }.count
                XCTAssertEqual(singles % 2, 0, "\(path):\(i + 1) DolDoc commands balanced")
            }
        }
    }

    /** Every way into a file reads the same moderated bytes: the filesystem has no unmoderated copy. */
    func testEveryPathReadsTheModeratedText() {
        let sh = Shell(env); sh.resize(360, 640)
        let fsText = String(decoding: env.fs.readFile("C:/Adam/God/HSNotes.DD")!, as: UTF8.self)
        XCTAssertTrue(fsText.contains("[Derogatory remark redacted]"))
        // the editor (Edit source, Files > Edit) shows the same text
        Launch.editor(sh, "C:/Adam/God/HSNotes.DD"); _ = sh.tick()
        let ed = sh.focused!.app as! EditorApp
        XCTAssertTrue(ed.text().contains("[Derogatory remark redacted]"))
        // God Words' "Holy Spirit instructions" opens the moderated document
        Launch.doc(sh, "C:/Adam/God/HSNotes.DD"); _ = sh.tick()
        XCTAssertTrue((sh.focused!.app as! DocViewerApp).documentText().contains("[Derogatory remark redacted]"))
    }

    /** Documents stay in English with the same edits whatever the UI language; the notice is localized. */
    func testLanguagesShowTheSameModeratedDocument() {
        let sh = Shell(env); sh.resize(360, 640)
        var texts: [String] = []
        for loc in ["en-US", "ar", "ja-JP", "de-DE"] {
            sh.settings.language = loc; sh.applyLanguage()
            let d = DocViewerApp(sh, "C:/Adam/God/HSNotes.DD")
            texts.append(d.documentText(80))
        }
        XCTAssertEqual(Set(texts).count, 1, "the document does not change with the language")
        // every catalog has the moderation notice and About wording; machine translations are flagged for review
        let l10n = SHARED.appendingPathComponent("runtime/l10n")
        let files = try! FileManager.default.contentsOfDirectory(atPath: l10n.path).filter { $0.hasSuffix(".json") && $0 != "locales.json" }
        XCTAssertEqual(files.count, 73)
        for f in files {
            let c = try! Json.parse(String(decoding: readFileBytes(l10n.appendingPathComponent(f))!, as: UTF8.self)) as! [String: Any?]
            for k in ["doc.notice.adapted.body", "about.how.body"] {
                XCTAssertFalse(((c[k] as? String) ?? "").isEmpty, "\(f): \(k)")
                if f != "en.json" { XCTAssertTrue(((c["$review"] as? [Any?]) ?? []).contains { $0 as? String == k } || f == "en.json", "\(f): \(k) flagged for review") }
            }
            XCTAssertTrue(((c["about.how.body"] as? String) ?? "").contains("Terry A. Davis"), "\(f): About names Terry A. Davis")
        }
    }

    /** About says that some wording was edited, by the project, and that inclusion is not endorsement (CONTENT_MODERATION.md §5). */
    func testAboutDescribesTheEditsWithoutClaimingCompleteness() {
        let c = try! Json.parse(String(decoding: readFileBytes(SHARED.appendingPathComponent("runtime/l10n/en.json"))!, as: UTF8.self)) as! [String: Any?]
        let en = c["about.how.body"] as! String
        for s in ["Some of the original wording", "censored or redacted by this project", "these edits are not Terry A. Davis' wording",
                  "does not mean endorsing every statement"] {
            XCTAssertTrue(en.contains(s), s)
        }
        XCTAssertFalse(en.contains("Offensive words and remarks about groups of people in the original files were"), "no claim that every offensive remark was removed")
        for loc in ["en-US", "de-DE", "ja-JP", "ar", "zh-CN"] {
            let sh = Shell(env); sh.resize(360, 640)
            sh.settings.language = loc; sh.applyLanguage()
            _ = sh.open(AboutApp(sh)); _ = sh.tick()
            let text = sh.accessibilityNodes().map { $0.label }.joined(separator: "\n")
            XCTAssertTrue(text.contains(L10n.tr("about.how.body")), "\(loc) shows the About moderation text")
            if loc != "en-US" { XCTAssertNotEqual(L10n.tr("about.how.body"), en, "\(loc) is translated") }
        }
    }
}
