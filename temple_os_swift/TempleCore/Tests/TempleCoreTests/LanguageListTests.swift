import Foundation
import XCTest
@testable import TempleCore

/** A seeded generator, so permutation tests repeat (Kotlin uses kotlin.random.Random(seed)). */
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/**
 * Port of LanguageListTest.kt (docs/localization.md, "Language lists"). Expected orders are never
 * written out whole: every result is checked against the display locale's own collation, and only
 * orders that hold in any CLDR-based collation are spelled out. Foundation reorders scripts for
 * the display locale, which the JVM's collator does not, so that is checked here only.
 */
final class LanguageListTests: XCTestCase {
    private var dirs: [URL] = []
    private var shells: [Shell] = [] // apps hold their shell unowned

    private func manifest() -> [String: Any?] {
        let d = try! Data(contentsOf: SHARED.appendingPathComponent("runtime/l10n/locales.json"))
        return try! Json.parse(String(decoding: d, as: UTF8.self)) as! [String: Any?]
    }

    private func manifestOptions(_ m: [String: Any?]? = nil) -> [LanguageOption] {
        LocaleResolver(m ?? manifest()).locales.map(LanguageList.option)
    }

    private func o(_ id: String, _ name: String, _ gloss: String) -> LanguageOption { LanguageOption(id, name, gloss) }

    private lazy var sample: [LanguageOption] = [
        o("es-ES", "Español (España)", "Spanish (Spain)"), o("ar", "العربية", "Arabic"), o("ja-JP", "日本語", "Japanese"),
        o("en-US", "English (United States)", "English (United States)"), o("fr-FR", "Français (France)", "French (France)"),
        o("de-DE", "Deutsch", "German"), o("ru-RU", "Русский", "Russian"), o("hi-IN", "हिन्दी", "Hindi"),
        o("cs-CZ", "Čeština", "Czech"), o("is-IS", "Íslenska", "Icelandic"), o("zu", "isiZulu", "Zulu"),
        o("es-419", "Español (Latinoamérica)", "Spanish (Latin America)"), o("fa", "فارسی", "Persian"),
    ]

    private func ids(_ l: [LanguageOption]) -> [String] { l.map(\.id) }

    private func assertOrdered(_ l: [LanguageOption], _ locale: String, file: StaticString = #filePath, line: UInt = #line) {
        let less = LanguageList.comparator(locale)
        for i in l.indices.dropFirst() {
            XCTAssertTrue(less(l[i - 1], l[i]) && !less(l[i], l[i - 1]), "\(l[i - 1]) before \(l[i]) (\(locale))", file: file, line: line)
        }
    }

    private func before(_ l: [LanguageOption], _ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        let ia = ids(l).firstIndex(of: a), ib = ids(l).firstIndex(of: b)
        XCTAssertTrue(ia != nil && ib != nil && ia! < ib!, "\(a) before \(b) in \(ids(l))", file: file, line: line)
    }

    private func entry(_ id: String, _ native: String?, _ english: String?) -> [String: Any?] {
        var e: [String: Any?] = ["id": id, "catalog": "en", "parent": nil, "language": id, "script": nil, "direction": "ltr",
                                 "family_default": false, "aliases": [Any?]()]
        if let native { e["native_name"] = native }
        if let english { e["english_name"] = english }
        return e
    }

    override func tearDown() {
        L10n.use("en-US")
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll(); shells.removeAll()
        super.tearDown()
    }

    private func env() -> LangEnv {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-langlist-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return LangEnv(HeadlessEnv(u), ["en-US"])
    }

    private func shell(_ env: LangEnv, _ w: Int = 320, _ h: Int = 480) -> Shell {
        let sh = Shell(env); sh.resize(w, h); sh.restoreSession(); _ = sh.tick()
        shells.append(sh)
        return sh
    }

    func testShuffledInputsGiveOneOrder() {
        let pick = { (order: [String]) in order.map { id in self.sample.first { $0.id == id }! } }
        for loc in ["en-US", "es-ES", "ja-JP", "ar", "ru-RU"] {
            let want = LanguageList.sorted(pick(["es-ES", "ar", "ja-JP", "en-US", "fr-FR", "de-DE"]), loc)
            XCTAssertEqual(want, LanguageList.sorted(pick(["de-DE", "fr-FR", "en-US", "ja-JP", "ar", "es-ES"]), loc))
            XCTAssertEqual(want, LanguageList.sorted(pick(["ja-JP", "es-ES", "fr-FR", "ar", "de-DE", "en-US"]), loc))
            assertOrdered(want, loc)
        }
    }

    func testPropertiesOverRandomPermutations() {
        let all = manifestOptions()
        var rnd = SplitMix64(89)
        for loc in ["en-US", "de-DE", "es-419", "sv-SE", "tr-TR", "ru-RU", "ja-JP", "zh-CN", "ar", "he-IL", "hi-IN", "th"] {
            let want = LanguageList.sorted(all, loc)
            assertOrdered(want, loc)
            XCTAssertEqual(Set(all.map(\.id)), Set(want.map(\.id)), "same identities")
            XCTAssertEqual(all.count, want.count)
            XCTAssertEqual(want, LanguageList.sorted(want, loc), "idempotent")
            XCTAssertEqual(want, LanguageList.sorted(want.reversed(), loc), "reverse")
            for _ in 0..<25 { XCTAssertEqual(want, LanguageList.sorted(all.shuffled(using: &rnd), loc), "permutation") }
        }
    }

    func testVisibleNamesNotIdsOrEnglishNames() {
        let en = LanguageList.sorted(manifestOptions(), "en-US")
        // the list used to be sorted by the English name while showing the language's own name first
        before(en, "de-DE", "et")     // Deutsch, Eesti (German came after Estonian)
        before(en, "sq", "fi-FI")     // Shqip, Suomi
        before(en, "fi-FI", "sv-SE")  // Suomi, Svenska
        before(en, "nl-NL", "pl-PL")  // Nederlands, Polski (Dutch was among the D's)
        // and never by locale id: "hr" (Hrvatski) sorts among the H's, "eu-ES" (Euskara) among the E's
        before(en, "eu-ES", "fil")
        before(en, "gl-ES", "hr")
        XCTAssertEqual(89, en.count, "Automatic stays outside the language rows")
    }

    func testLatinAccentsAndCase() {
        for loc in ["en-US", "fr-FR", "de-DE", "pt-BR"] {
            let l = LanguageList.sorted(manifestOptions(), loc)
            before(l, "ca", "cs-CZ"); before(l, "cs-CZ", "da-DK")     // Català, Čeština, Dansk
            before(l, "en-US", "es-ES"); before(l, "es-MX", "eu-ES")  // English, Español, Euskara
            before(l, "zu", "is-IS"); before(l, "is-IS", "it-IT")     // isiZulu, Íslenska, Italiano
            before(l, "sk", "sl")                                     // Slovenčina, Slovenščina
        }
        // canonical equivalence: precomposed and decomposed "ñ" are the same label; the id decides
        let nfc = o("zz-b", "Espa\u{00F1}ol", "Spanish"), nfd = o("zz-a", "Espan\u{0303}ol", "Spanish")
        XCTAssertEqual(["zz-a", "zz-b"], ids(LanguageList.sorted([nfc, nfd], "es-ES")))
        XCTAssertEqual(["zz-a", "zz-b"], ids(LanguageList.sorted([nfd, nfc], "es-ES")))
        // case is a later level than letters
        let mixed = [o("x1", "beta", "b"), o("x2", "Alpha", "a"), o("x3", "ALPHA", "a"), o("x4", "Beta", "b")]
        let got = LanguageList.sorted(mixed, "en-US")
        XCTAssertEqual(Set(["x2", "x3"]), Set(ids(got).prefix(2)))
        XCTAssertEqual(got, LanguageList.sorted(mixed.reversed(), "en-US"))
    }

    func testOtherScriptsKeepTheirText() {
        let all = manifestOptions()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for loc in ["en-US", "ru-RU", "ar", "ja-JP", "hi-IN"] {
            let l = LanguageList.sorted(all, loc)
            for x in l { XCTAssertEqual(byId[x.id]!.label, x.label) }
            before(l, "be", "bg"); before(l, "bg", "ru-RU"); before(l, "ru-RU", "uk") // Беларуская, Български, Русский, Українська
            before(l, "ur", "ar"); before(l, "ar", "fa")                               // اردو, العربية, فارسی (right to left)
            before(l, "fa", "fa-AF")                                                   // فارسی, فارسی دری (افغانستان)
            before(l, "ne-NP", "mr-IN"); before(l, "mr-IN", "hi-IN")                   // नेपाली, मराठी, हिन्दी
        }
        XCTAssertEqual("العربية - Arabic", byId["ar"]!.label)
        XCTAssertEqual("日本語 - Japanese", byId["ja-JP"]!.label)
        // the display locale's script first (Foundation collation, as on Android with ICU)
        func firstScript(_ loc: String, _ ids: [String]) {
            let head = Array(LanguageList.sorted(all, loc).prefix(ids.count)).map(\.id)
            XCTAssertEqual(Set(ids), Set(head), loc)
        }
        firstScript("ru-RU", ["be", "bg", "ky-KG", "kk", "mk-MK", "mn-MN", "ru-RU", "sr", "uk"])
        firstScript("ar", ["ur", "ar", "fa", "fa-AE", "fa-IR", "fa-AF"])
        firstScript("el-GR", ["el-GR"])
        let en = LanguageList.sorted(all, "en-US")
        let latin = en.map { $0.name.unicodeScalars.first!.value < 0x370 }
        XCTAssertEqual(latin.sorted { $0 && !$1 }, latin, "Latin names first in English")
        XCTAssertEqual(48, latin.filter { $0 }.count)
    }

    func testRegionAndScriptVariantsStayDistinct() {
        let l = LanguageList.sorted(manifestOptions(), "en-US")
        for v in ["en-US", "en-GB", "en-AU", "en-CA", "en-IN", "en-SG", "en-ZA", "es-419", "es-ES", "es-MX", "es-US",
                  "fr-FR", "fr-CA", "pt-BR", "pt-PT", "zh-CN", "zh-TW", "zh-HK", "ms", "ms-MY", "fa", "fa-IR", "fa-AF", "fa-AE"] {
            XCTAssertEqual(1, l.filter { $0.id == v }.count, v)
        }
        XCTAssertEqual(l.count, Set(l.map(\.label)).count, "every row reads differently")
        before(l, "es-ES", "es-US"); before(l, "es-US", "es-419"); before(l, "es-419", "es-MX")
        before(l, "ms", "ms-MY")
        let sr = [o("sr-Latn", "Srpski (latinica)", "Serbian (Latin)"), o("sr-Cyrl", "Српски (ћирилица)", "Serbian (Cyrillic)")]
        XCTAssertEqual(Set(["sr-Latn", "sr-Cyrl"]), Set(ids(LanguageList.sorted(sr, "en-US"))))
        XCTAssertEqual(LanguageList.sorted(sr, "sr"), LanguageList.sorted(sr.reversed(), "sr"))
    }

    func testMissingNamesUnknownCodesAndDuplicates() {
        XCTAssertEqual([], LanguageList.sorted([LanguageOption](), "en-US"))
        XCTAssertEqual(["de-DE"], ids(LanguageList.sorted([sample.first { $0.id == "de-DE" }!], "en-US")))
        var m = manifest()
        var locs = (m["locales"] as! [Any?])
        locs.append(entry("qaa", nil, nil))
        locs.append(entry("qab", "  ", "Testish"))
        m["locales"] = locs
        let opts = manifestOptions(m)
        XCTAssertEqual("qaa - qaa", opts.first { $0.id == "qaa" }!.label)
        XCTAssertEqual("Testish - Testish", opts.first { $0.id == "qab" }!.label)
        let l = LanguageList.sorted(opts, "en-US")
        XCTAssertEqual(91, l.count)
        before(l, "pl-PL", "qaa"); before(l, "qaa", "ro")
        before(l, "sv-SE", "qab"); before(l, "qab", "th")
        let de = sample.first { $0.id == "de-DE" }!
        let dup = [de, sample.first { $0.id == "ar" }!, de, o("de-DE", "Deutsch (alt)", "German (alt)")]
        let once = LanguageList.sorted(dup, "en-US")
        XCTAssertEqual(["de-DE", "ar"], ids(once))
        XCTAssertEqual("Deutsch", once[0].name)
        XCTAssertEqual(once, LanguageList.sorted(dup.reversed(), "en-US"))
    }

    func testEqualLabelsBreakTiesById() {
        let twins = [o("xx-b", "Same", "Same"), o("xx-c", "Same", "Same"), o("xx-a", "Same", "Same"), o("XX-A", "Same", "Same")]
        var rnd = SplitMix64(3)
        for p in [twins, twins.reversed(), twins.shuffled(using: &rnd)] {
            XCTAssertEqual(["XX-A", "xx-a", "xx-b", "xx-c"], ids(LanguageList.sorted(p, "en-US")))
        }
        let g = [o("a2", "Norsk", "Norwegian Nynorsk"), o("a1", "Norsk", "Norwegian Bokmal")]
        XCTAssertEqual(["a1", "a2"], ids(LanguageList.sorted(g, "en-US")))
    }

    func testLanguagesAddedLaterFindTheirPlace() {
        var m = manifest()
        var locs = (m["locales"] as! [Any?])
        locs.append(entry("an", "Aragonés", "Aragonese"))
        locs.insert(entry("cy-GB", "Cymraeg", "Welsh"), at: 0)
        locs.insert(entry("mt", "Malti", "Maltese"), at: 40)
        locs.append(entry("yo", "Yorùbá", "Yoruba"))
        m["locales"] = locs
        let l = LanguageList.sorted(manifestOptions(m), "en-US")
        XCTAssertEqual(93, l.count)
        assertOrdered(l, "en-US")
        before(l, "af", "an"); before(l, "an", "az-AZ")
        before(l, "cs-CZ", "cy-GB"); before(l, "cy-GB", "da-DK")
        before(l, "hu-HU", "mt"); before(l, "mt", "nl-NL")
        before(l, "tr-TR", "yo"); before(l, "yo", "el-GR")
        XCTAssertEqual(89, manifestOptions().count)
    }

    func testCurrentFollowsTheUiLanguage() {
        let sh = shell(env())
        let all = L10n.resolver!.locales.map(LanguageList.option)
        let en = LanguageList.current()
        XCTAssertEqual(LanguageList.sorted(all, "en-US"), en)
        for loc in ["ru-RU", "ar", "es-419", "ja-JP", "ru-RU", "en-US"] {
            L10n.use(loc)
            XCTAssertEqual(LanguageList.sorted(all, loc), LanguageList.current(), loc)
        }
        XCTAssertEqual(en, LanguageList.current(), "rebuilt, not stale")
        withExtendedLifetime(sh) {}
    }

    /** The rows the Language window shows, top to bottom, collected by scrolling through it. */
    private func windowRows(_ sh: Shell, _ lang: LanguageApp, _ known: Set<String>) -> ([String], String?) {
        let r = sh.clientRect(sh.findWindow("language")!)
        lang.scroll(0, 100_000, r); _ = sh.tick()
        var out: [String] = []
        var selected: String? = nil
        for _ in 0..<200 {
            sh.invalidate(); _ = sh.tick()
            let rows = sh.accessibilityNodes().filter { $0.button && known.contains($0.label) }.sorted { $0.rect.y < $1.rect.y }
            if let s = rows.first(where: { $0.selected }) { selected = s.label }
            let fresh = Array(rows.map(\.label).drop { out.contains($0) })
            if fresh.isEmpty { return (out, selected) }
            out += fresh
            lang.scroll(0, -ROW_H * max(1, rows.count - 1), r)
        }
        return (out, selected)
    }

    func testLanguageWindowShowsTheOrderAndKeepsTheSelection() {
        let e = env()
        let sh = shell(e)
        Launch.language(sh); _ = sh.tick()
        let lang = sh.findWindow("language")!.app as! LanguageApp
        let auto = tr("settings.language.automatic")
        let labels = LanguageList.current().map(\.label)
        let (rows, sel) = windowRows(sh, lang, Set(labels + [auto]))
        XCTAssertEqual([auto] + labels, rows)
        XCTAssertEqual(auto, sel, "Automatic is the current choice")

        let r = sh.clientRect(sh.findWindow("language")!)
        lang.scroll(0, 100_000, r)
        var node: A11yNode? = nil
        for _ in 0..<200 {
            sh.invalidate(); _ = sh.tick()
            node = sh.accessibilityNodes().first { $0.button && $0.label == "Русский - Russian" }
            if node != nil { break }
            lang.scroll(0, -ROW_H, r)
        }
        sh.accessibilityActivate(node!); sh.invalidate(); _ = sh.tick()
        XCTAssertEqual("ru-RU", sh.settings.language)
        XCTAssertEqual("ru-RU", L10n.locale?.id)
        let after = sh.accessibilityNodes().first { $0.button && $0.label == "Русский - Russian" }!
        XCTAssertTrue(after.selected, "selected by id")
        XCTAssertEqual(node!.rect.y, after.rect.y, "the chosen row stays under the finger")
        let ru = LanguageList.current().map(\.label)
        let autoRu = tr("settings.language.automatic")
        XCTAssertNotEqual(auto, autoRu, "the special row is translated, the language rows are not")
        XCTAssertEqual(LanguageList.sorted(LanguageList.current(), "ru-RU").map(\.label), ru)
        XCTAssertTrue(ru.first!.hasPrefix("Беларуская"), "Russian collation puts Cyrillic first")
        let (rowsRu, selRu) = windowRows(sh, lang, Set(ru + [autoRu]))
        XCTAssertEqual([autoRu] + ru, rowsRu)
        XCTAssertEqual("Русский - Russian", selRu)

        sh.saveSession(); L10n.use("en-US")
        let sh2 = shell(e, 480, 320)
        XCTAssertEqual("ru-RU", sh2.settings.language)
        if sh2.findWindow("language") == nil { Launch.language(sh2); _ = sh2.tick() }
        let lang2 = sh2.findWindow("language")!.app as! LanguageApp
        XCTAssertEqual("Русский - Russian", windowRows(sh2, lang2, Set(ru + [autoRu])).1)
    }

    func testCollatorIsTheDisplayLocales() {
        let words = ["Ö", "Z", "Å", "A", "Ä"].enumerated().map { o("x\($0.offset)", $0.element, $0.element) }
        let sv = LanguageList.sorted(words, "sv-SE").map(\.name)
        let en = LanguageList.sorted(words, "en-US").map(\.name)
        XCTAssertTrue(sv.firstIndex(of: "Z")! < sv.firstIndex(of: "Å")! && sv.firstIndex(of: "Z")! < sv.firstIndex(of: "Ö")!, "\(sv)")
        XCTAssertTrue(en.firstIndex(of: "Ö")! < en.firstIndex(of: "Z")! && en.firstIndex(of: "Å")! < en.firstIndex(of: "Z")!, "\(en)")
    }
}
