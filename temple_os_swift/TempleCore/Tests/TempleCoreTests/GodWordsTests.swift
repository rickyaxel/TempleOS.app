import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of GodWordsTest.kt: Terry's vocabulary and selection (Adam/God/HolySpirit.HC) and its
 * localization (docs/localization-vocabulary.md), against the same shared vectors
 * (shared/test-vectors/god-words/vectors.json) as the Kotlin suite.
 */
final class GodWordsTests: XCTestCase {
    private var v: [String: Any?] = [:]
    private var latches: [Int64] = []
    private var picks: [Int] = []
    private var actions: [String] = []
    private var reads: [Int] = []
    private var dir: URL!
    private var env: HeadlessEnv!

    override func setUp() {
        let text = String(decoding: readFileBytes(SHARED.appendingPathComponent("test-vectors/god-words/vectors.json"))!, as: UTF8.self)
        v = (try! Json.parse(text)) as! [String: Any?]
        latches = (v["latches"] as! [Any?]).map { Int64(truncating: $0 as! NSNumber) }
        picks = (v["picks"] as! [Any?]).map { Int(truncating: $0 as! NSNumber) }
        actions = (v["actions"] as! [Any?]).map { $0 as! String }
        reads = (v["reads_after_action"] as! [Any?]).map { Int(truncating: $0 as! NSNumber) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-god-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env = HeadlessEnv(dir)
        L10n.initialize(env.runtimeFile)
        L10n.use("en-US")
    }

    override func tearDown() { L10n.use("en-US"); try? FileManager.default.removeItem(at: dir) }

    /** A God Words window whose timer returns the vectors' latches, counting how often it is read. */
    private final class Clock {
        let values: [Int64]; var reads = 0
        init(_ v: [Int64]) { values = v }
        func next() -> Int64 { defer { reads += 1 }; return values[reads] }
    }

    private func god(_ clock: Clock) -> (Shell, GodApp) {
        let sh = Shell(env); sh.resize(360, 640)
        let g = GodApp(sh, clock: { clock.next() })
        _ = sh.open(g); _ = sh.tick()
        return (sh, g)
    }

    /** Presses the vectors' button `k` ("ten" = 10 WORDS, "word" = WORD). */
    private func press(_ g: GodApp, _ k: Int) { if actions[k] == "ten" { g.tenWordsButton() } else { g.wordButton() } }
    /** Picks made by the first `k` presses. */
    private func picksAfter(_ k: Int) -> [Int] { Array(picks.prefix(actions.prefix(k).reduce(0) { $0 + ($1 == "ten" ? 10 : 1) })) }

    private func vocab() -> [String] { GodVocab.tokenize(env.fs.readFile("C:/Adam/God/Vocab.DD")!) }
    private func strings(_ k: String) -> [String] { (v[k] as! [Any?]).map { $0 as! String } }
    private func display(_ loc: String) -> [String] { ((v["display"] as! [String: Any?])[loc] as! [Any?]).map { $0 as! String } }
    private func language(_ sh: Shell, _ loc: String) { sh.settings.language = loc; sh.applyLanguage(); _ = sh.tick() }

    func testVocabularyIsSplitAsGodInitSplitsIt() {
        let words = vocab()
        XCTAssertEqual(Int(truncating: v["count"] as! NSNumber), words.count)
        XCTAssertEqual(7569, words.count)
        XCTAssertEqual(v["sha256"] as? String, GodVocab.digest(words))
        for (i, w) in v["spot"] as! [String: Any?] { XCTAssertEqual(w as? String, words[Int(i)!], "entry \(i)") }
        // digits, '_' and bytes >= 128 are word characters (Kernel/StrA.HC char_bmp_word); no entry is merged or dropped
        XCTAssertEqual("etext00", words[2314]); XCTAssertEqual("tcosa10a", words[6587])
        XCTAssertEqual(GodVocab.tokenize(Array("ab1_c'd-x".utf8) + [0] + Array("ignored".utf8)), ["ab1_c'd", "x"])
        XCTAssertEqual(GodVocab.tokenize([0x63, 0x61, 0x66, 0x82]), ["caf\u{e9}"])
        // duplicates stay separate entries (no dedup): the bundled list has "delay" twice (5592 is moderation edit VO-5593)
        XCTAssertEqual(words.count - 1, Set(words).count)
        XCTAssertEqual([1625, 5592], words.indices.filter { words[$0] == "delay" })
    }

    func testBundledVocabularyMatchesTheIsoExceptTheDocumentedReplacement() throws {
        guard let original = readFileBytes(REFERENCE.appendingPathComponent("templeos-iso/Adam/God/Vocab.DD")) else {
            throw XCTSkip("reference/templeos-iso is not on this machine")
        }
        let iso = GodVocab.tokenize(original)
        let words = vocab()
        XCTAssertEqual(iso.count, words.count)
        let diff = iso.indices.filter { iso[$0] != words[$0] }
        XCTAssertEqual((v["iso_differs_at"] as! [String: Any?]).keys.map { Int($0)! }.sorted(), diff)
        XCTAssertEqual([5592], diff)
        // the original word is identified by its hash, not spelled out (tools/resource-packaging/moderation.json VO-5593)
        XCTAssertEqual(sha256Hex(Array(iso[5592].utf8)), "158869a97379229b7681efae9d7f9c9214134e836d649ba53477c0c111414d59")
        XCTAssertEqual("delay", words[5592])
    }

    func testPicksFollowGodBitsModuloTheVocabulary() {
        let clock = Clock(latches)
        let (sh, g) = god(clock)
        defer { withExtendedLifetime(sh) {} } // apps hold their shell unowned
        // every button is TempleOS's F7: flush, one latch; GodBits latches again only when the FIFO runs dry
        for k in actions.indices {
            press(g, k)
            XCTAssertEqual(picksAfter(k + 1), g.picks, "picks after press \(k)")
            XCTAssertEqual(reads[k], clock.reads, "timer reads after press \(k)")
        }
        XCTAssertTrue(g.text().contains(strings("english").prefix(10).joined(separator: " ")))
    }

    func testChangingTheLanguageShowsTheSamePicksAndDrawsNoBits() {
        let clock = Clock(latches)
        let (sh, g) = god(clock)
        press(g, 0); _ = sh.tick()
        for loc in ["es-ES", "fr-FR", "en-US", "ja-JP", "ar", "he-IL", "zh-CN", "ko-KR", "hi-IN", "ru-RU", "th", "am", "es-ES"] {
            language(sh, loc)
            XCTAssertEqual(loc, L10n.locale?.id)
            XCTAssertEqual(reads[0], clock.reads, "no timer reads on a language change (\(loc))")
            XCTAssertEqual(picksAfter(1), g.picks)
            let shown = loc == "en-US" ? strings("english") : display(loc)
            XCTAssertTrue(g.text().contains(shown.prefix(10).joined(separator: " ")), "\(loc) shows the same ten entries")
        }
        // the next press continues exactly as if no language change had happened: rendering consumed nothing
        press(g, 1)
        XCTAssertEqual(picksAfter(2), g.picks)
        XCTAssertEqual(reads[1], clock.reads)
        XCTAssertTrue(g.text().contains(display("es-ES")[10..<20].joined(separator: " ")))
    }

    func testLanguageSwitchesLoadEachVocabularyOnce() {
        let (sh, g) = god(Clock(latches))
        g.tenWordsButton()
        language(sh, "de-DE")
        let n = GodVocab.loads
        for _ in 0..<5 { sh.invalidate(); _ = sh.tick(); _ = g.text() }
        XCTAssertEqual(n, GodVocab.loads)
        language(sh, "ja-JP")
        XCTAssertEqual(n + 1, GodVocab.loads)
    }

    func testEverySupportedCatalogHasAValidVocabularyFile() {
        let words = vocab()
        let digest = GodVocab.digest(words)
        let m = (try! Json.parse(String(decoding: env.runtimeFile("l10n/locales.json")!, as: UTF8.self))) as! [String: Any?]
        let cats = Set((m["locales"] as! [Any?]).map { (($0 as! [String: Any?])["catalog"] as! String) }).subtracting(["en"]).sorted()
        XCTAssertEqual(72, cats.count)
        var present = 0
        for c in cats {
            let t = GodVocab.table(c, digest, words.count, env.runtimeFile)
            XCTAssertEqual("ok", t.status, "\(c) loads")
            present += t.translated
            for i in words.indices {
                guard let s = t.translation(i) else { continue }
                XCTAssertEqual(s, s.precomposedStringWithCanonicalMapping, "\(c) \(i) is NFC")
                XCTAssertFalse(s.contains("{") || s.contains("TODO") || s.contains("\u{FFFD}"), "\(c) \(i) has no placeholder")
            }
        }
        print("God Words coverage: \(present) / \(cats.count * words.count)")
    }

    /** The same entries as the Kotlin test decode to the same text: both platforms read one shipped file. */
    func testTranslationsMatchTheSharedVectors() {
        let words = vocab()
        let digest = GodVocab.digest(words)
        let m = (try! Json.parse(String(decoding: env.runtimeFile("l10n/locales.json")!, as: UTF8.self))) as! [String: Any?]
        var catOf: [String: String] = [:]
        for l in m["locales"] as! [Any?] { let d = l as! [String: Any?]; catOf[d["id"] as! String] = d["catalog"] as? String }
        for (loc, shown) in v["display"] as! [String: Any?] {
            let t = GodVocab.table(catOf[loc]!, digest, words.count, env.runtimeFile)
            XCTAssertEqual((shown as! [Any?]).map { $0 as! String }, picks.map { t.translation($0) ?? words[$0] }, loc)
        }
    }

    func testBrokenOrMismatchedFilesFallBackToEnglishWithoutRerolling() {
        let words = ["alpha", "beta", "gamma"]
        let digest = GodVocab.digest(words)
        let good = "\(GodVocab.FORMAT) count=3 sha256=\(digest)\nα\n\nγ\u{7}\n"
        var files: [String: [UInt8]] = [:]
        files["l10n/vocab/xx.deflate"] = deflate(good)
        let src: (String) -> [UInt8]? = { files[$0] }
        let t = GodVocab.table("xx", digest, 3, src)
        XCTAssertEqual("ok", t.status)
        XCTAssertEqual("α", t.translation(0))
        XCTAssertNil(t.translation(1), "empty = not translated")
        XCTAssertNil(t.translation(2), "control character = invalid")
        XCTAssertNil(t.translation(3), "index past the end")
        XCTAssertEqual("missing", GodVocab.table("yy", digest, 3, src).status)
        files["l10n/vocab/zz.deflate"] = deflate(good.replacingOccurrences(of: digest, with: String(repeating: "0", count: 64)))
        XCTAssertEqual("mismatch", GodVocab.table("zz", digest, 3, { files[$0] }).status)
        files["l10n/vocab/ww.deflate"] = [1, 2, 3, 4, 5]
        XCTAssertEqual("corrupt", GodVocab.table("ww", digest, 3, { files[$0] }).status)
        files["l10n/vocab/vv.deflate"] = deflate("\(GodVocab.FORMAT) count=3 sha256=\(digest)\nα\n")
        XCTAssertEqual("corrupt", GodVocab.table("vv", digest, 3, { files[$0] }).status)
        XCTAssertEqual("english", GodVocab.table("en", digest, 3, { files[$0] }).status)
    }

    /** Prints load, generation and redraw costs (docs/fidelity-audit/TEMPLEOS_10_WORDS_VALIDATION.md). */
    func testVocabularyCosts() {
        let words = vocab()
        let digest = GodVocab.digest(words)
        var loads: [Double] = []
        for c in ["de", "ja", "ar", "zh-Hans", "ru", "hi", "th", "es", "ko", "fr"] where env.runtimeFile("l10n/vocab/\(c).deflate") != nil {
            _ = GodVocab.table("en", digest, words.count, env.runtimeFile) // drop the cache
            let t0 = monoNanos()
            let t = GodVocab.table(c, digest, words.count, env.runtimeFile)
            loads.append(Double(monoNanos() - t0) / 1e6)
            XCTAssertEqual("ok", t.status)
        }
        let many = (0..<2000).map { latches[$0 % latches.count] &+ Int64($0) * 7919 }
        let (sh, g) = god(Clock(many))
        language(sh, "ja-JP")
        var gen: [Double] = []
        for _ in 0..<20 {
            let t0 = monoNanos(); g.tenWordsButton(); sh.invalidate(); _ = sh.tick(); gen.append(Double(monoNanos() - t0) / 1e6)
        }
        let s0 = monoNanos()
        language(sh, "ar")
        let switchMs = Double(monoNanos() - s0) / 1e6
        loads.sort(); gen.sort()
        print(String(format: "GODWORDS-COST load ms median %.1f max %.1f (%d catalogs); 10 WORDS + redraw ms median %.2f max %.2f; language switch with 200 words shown %.1f ms",
                     loads[loads.count / 2], loads.last!, loads.count, gen[gen.count / 2], gen.last!, switchMs))
        XCTAssertLessThan(loads.last!, 2000)
    }

    /** Raw DEFLATE via the same file the tool writes: a bundled catalog's bytes are reused when possible. */
    private func deflate(_ text: String) -> [UInt8] {
        let src = Array(text.utf8)
        var dst = [UInt8](repeating: 0, count: src.count + 1024)
        let n = compressRaw(src, &dst)
        return Array(dst[0..<n])
    }

    func testAChangedVocabularyIsShownInEnglish() {
        // a user's own Vocab.DD (the drive is writable) has other entries: translations of Terry's list must not be applied
        try! env.fs.writeFile("C:/Adam/God/Vocab.DD", Array("one two three\n".utf8))
        let (sh, g) = god(Clock(latches))
        language(sh, "es-ES")
        g.tenWordsButton()
        let words = g.text().components(separatedBy: "\n").last!.components(separatedBy: " ")
        XCTAssertEqual(10, words.count)
        XCTAssertTrue(words.allSatisfy { ["one", "two", "three"].contains($0) })
    }

    func testDocumentNoticeFollowsVerifiedProvenance() {
        let fs = env.fs
        XCTAssertEqual(.ORIGINAL, DocProvenance.of(fs, "C:/Doc/HelpIndex.DD"))
        // HSNotes, Strategy and Charter carry content-moderation edits (docs/content-moderation): adapted, not original
        XCTAssertEqual(.ADAPTED, DocProvenance.of(fs, "C:/Adam/God/HSNotes.DD"))
        XCTAssertEqual(.ADAPTED, DocProvenance.of(fs, "C:/Doc/Strategy.DD"))
        XCTAssertEqual(.ADAPTED, DocProvenance.of(fs, "C:/Adam/God/Vocab.DD"))
        XCTAssertEqual(.INCLUDED, DocProvenance.of(fs, "C:/Misc/Bible.TXT"))
        XCTAssertEqual(.INCLUDED, DocProvenance.of(fs, "C:/Misc/PCIDevices.DD"))
        XCTAssertEqual(.MOBILE, DocProvenance.of(fs, "C:/Home/Welcome.DD"))
        XCTAssertEqual(.USER, DocProvenance.of(fs, "C:/Home/Mine.DD"))
        try! fs.writeFile("C:/Doc/Credits.DD", Array("mine".utf8))
        XCTAssertEqual(.CHANGED, DocProvenance.of(fs, "C:/Doc/Credits.DD"))
        try! fs.restoreOriginal("C:/Doc/Credits.DD")
        XCTAssertEqual(.ORIGINAL, DocProvenance.of(fs, "C:/Doc/Credits.DD"))
    }

    func testDocumentNoticeIsAboveTheDocumentAndLocalized() {
        let before = readFileBytes(SHARED.appendingPathComponent("bundled-fs/Doc/HelpIndex.DD"))!
        let sh = Shell(env); sh.resize(360, 640)
        let d = DocViewerApp(sh, "C:/Doc/HelpIndex.DD")
        _ = sh.open(d); _ = sh.tick()
        func nodes() -> [String] { sh.accessibilityNodes().filter { !$0.button }.map { $0.label } }
        let title = L10n.tr("doc.notice.original.title")
        let n = nodes()
        guard let i = n.firstIndex(where: { $0.hasPrefix(title) }) else { return XCTFail("notice shown: \(n)") }
        XCTAssertTrue(n[i].contains("Terry A. Davis"))
        XCTAssertFalse(n.dropFirst(i + 1).contains { $0.contains(title) }, "the notice is not part of the document text")
        XCTAssertTrue(n.dropFirst(i + 1).contains { $0.contains("Help") }, "the document follows the notice")
        // the notice scrolls away with the document
        for _ in 0..<12 { _ = d.key(0, Int64(Keys.SC_CURSOR_DOWN), true) }
        _ = sh.tick()
        XCTAssertTrue(nodes().allSatisfy { !$0.hasPrefix(title) })
        language(sh, "fr-FR")
        d.load("C:/Doc/HelpIndex.DD"); _ = sh.tick()
        XCTAssertTrue(nodes().contains { $0.hasPrefix(L10n.tr("doc.notice.original.title")) && $0.contains("Terry A. Davis") })
        XCTAssertNotEqual(title, L10n.tr("doc.notice.original.title"))
        XCTAssertEqual(before, env.fs.readFile("C:/Doc/HelpIndex.DD"), "the original file is unchanged")
    }

    /** Words of the file's text outside DolDoc commands, as the viewer must show them (in order). */
    private func proseWords(_ file: String) -> [String] {
        let t = Array(textPart(readFileBytes(SHARED.appendingPathComponent("bundled-fs/\(file)"))!))
        var plain: [Character] = []
        var i = 0
        while i < t.count {
            if t[i] == "$" {
                if i + 1 < t.count && t[i + 1] == "$" { plain.append("$"); i += 2; continue }
                guard let j = t[(i + 1)...].firstIndex(of: "$") else { break }
                i = j + 1; continue // a command's own text (links, $TX) is not counted: only the prose around it
            }
            plain.append(t[i]); i += 1
        }
        return letters(String(plain))
    }

    /** Runs of letters and digits: punctuation next to a link (`"$LK,...$"`) belongs to neither side. */
    private func letters(_ s: String) -> [String] { s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }

    func testTheViewerKeepsTheDocumentsWords() {
        let sh = Shell(env); sh.resize(360, 640)
        for file in ["Doc/HelpIndex.DD", "Doc/Credits.DD", "Adam/God/HSNotes.DD", "Doc/Welcome.DD", "Doc/FAQ.DD"] {
            let d = DocViewerApp(sh, "C:/\(file)")
            let shown = letters(d.documentText())
            var k = 0
            for w in proseWords(file) {
                while k < shown.count && !shown[k].hasPrefix(w) && !shown[k].hasSuffix(w) { k += 1 }
                XCTAssertTrue(k < shown.count, "\(file): '\(w)' is shown in order")
                if k >= shown.count { break }
                k += 1
            }
        }
    }

    func testAboutPageAcknowledgesTheModernAdditions() {
        let en = (try! Json.parse(String(decoding: readFileBytes(SHARED.appendingPathComponent("runtime/l10n/en.json"))!, as: UTF8.self))) as! [String: Any?]
        for loc in ["en-US", "es-ES", "ja-JP", "ar"] {
            let sh = Shell(env); sh.resize(360, 640)
            language(sh, loc)
            _ = sh.open(AboutApp(sh)); _ = sh.tick()
            let text = sh.accessibilityNodes().map { $0.label }.joined(separator: "\n")
            for k in ["about.additions.title", "about.additions.words", "about.additions.modern", "about.intro.creator", "about.credits.templeos"] {
                XCTAssertTrue(text.contains(L10n.tr(k)), "\(loc) shows \(k)")
            }
            if loc != "en-US" { XCTAssertNotEqual(L10n.tr("about.additions.modern"), en["about.additions.modern"] as? String, "\(loc) is translated") }
        }
        let e = (en["about.additions.modern"] as! String) + (en["about.additions.words"] as! String)
        XCTAssertTrue(e.contains("were not part of Terry A. Davis' original TempleOS"))
        XCTAssertFalse(e.contains("endorse") || e.contains("official TempleOS"))
    }
}

import Compression

/** Raw DEFLATE (Apple's COMPRESSION_ZLIB), for test fixtures. */
private func compressRaw(_ src: [UInt8], _ dst: inout [UInt8]) -> Int {
    let cap = dst.count
    return src.withUnsafeBufferPointer { s in
        dst.withUnsafeMutableBufferPointer { d in compression_encode_buffer(d.baseAddress!, cap, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB) }
    }
}
