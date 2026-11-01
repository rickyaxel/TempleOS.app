import Foundation
import XCTest
@testable import TempleCore

/** A headless shell whose device prefers [langs] (port of LangEnv in L10nTest.kt; Kotlin delegates with `by inner`). */
final class LangEnv: ShellEnv {
    let inner: HeadlessEnv
    var langs: [String]
    var region: String?
    init(_ inner: HeadlessEnv, _ langs: [String], _ region: String? = nil) { self.inner = inner; self.langs = langs; self.region = region }
    func runtimeFile(_ name: String) -> [UInt8]? { inner.runtimeFile(name) }
    var fs: LayeredFs { inner.fs }
    var stateStore: StateStore { inner.stateStore }
    func tone(_ freq: Double, at atNs: Int64) { inner.tone(freq, at: atNs) }
    func showKeyboard(_ show: Bool) { inner.showKeyboard(show) }
    func preferredLanguages() -> [String] { langs }
    func deviceRegion() -> String? { region }
    func measureText(_ s: String) -> Int { s.scLen * 9 }
}

/** Port of L10nTest.kt (docs/localization.md), plus catalog loading through [L10n]. */
final class L10nTests: XCTestCase {
    private let l10n = SHARED.appendingPathComponent("runtime/l10n")
    private var dirs: [URL] = []

    private func json(_ u: URL) -> [String: Any?] {
        let d = try! Data(contentsOf: u)
        return try! Json.parse(String(decoding: d, as: UTF8.self)) as! [String: Any?]
    }

    private func shell(_ langs: [String], _ region: String? = nil) -> (Shell, LangEnv) {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-l10n-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        let env = LangEnv(HeadlessEnv(u), langs, region)
        let sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); _ = sh.tick()
        return (sh, env)
    }

    override func tearDown() {
        L10n.use("en-US")
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll()
        super.tearDown()
    }

    func testResolverVectors() {
        let r = LocaleResolver(json(l10n.appendingPathComponent("locales.json")))
        let vectors = (json(SHARED.appendingPathComponent("test-vectors/l10n/resolver_vectors.json"))["vectors"] as! [Any?]).map { $0 as! [String: Any?] }
        XCTAssertGreaterThanOrEqual(vectors.count, 100)
        for v in vectors {
            let manual = (v["manual"] ?? nil) as? String
            let preferred = ((v["preferred"] ?? nil) as! [Any?]).map { $0 as! String }
            let region = (v["device_region"] ?? nil) as? String
            let got = r.resolve(manual, preferred, region)
            let name = (v["name"] ?? nil) as! String
            XCTAssertEqual(got.0, (v["expected"] ?? nil) as? String, name)
            XCTAssertEqual(got.1, (v["source"] ?? nil) as? String, name)
        }
    }

    func testManifestAndCatalogs() {
        let m = json(l10n.appendingPathComponent("locales.json"))
        let locales = (m["locales"] as! [Any?]).map { $0 as! [String: Any?] }
        XCTAssertEqual(89, locales.count)
        var catalogs: [String] = []
        for l in locales { let c = (l["catalog"] ?? nil) as! String; if !catalogs.contains(c) { catalogs.append(c) } }
        XCTAssertEqual(73, catalogs.count)
        let en = Set(json(l10n.appendingPathComponent("en.json")).keys.filter { !$0.hasPrefix("$") })
        XCTAssertFalse(en.isEmpty)
        // English loads through L10n
        _ = shell(["en-US"])
        XCTAssertEqual("en-US", L10n.locale?.id)
        for k in en { XCTAssertTrue(L10n.has(k), k) }
        XCTAssertEqual("CANCEL", tr("button.cancel"))
        var checked = 0
        for c in catalogs {
            let f = l10n.appendingPathComponent("\(c).json")
            if !FileManager.default.fileExists(atPath: f.path) { continue } // reported by tools/l10n/validate.py
            let keys = Set(json(f).keys.filter { !$0.hasPrefix("$") })
            XCTAssertEqual(en, keys, "catalog \(c)")
            // and it loads at runtime: the first locale using this catalog
            let id = (locales.first { (($0["catalog"] ?? nil) as? String) == c }!["id"] ?? nil) as! String
            L10n.use(id)
            XCTAssertEqual(id, L10n.locale?.id, "catalog \(c)")
            for k in en { XCTAssertTrue(L10n.has(k), "\(c): \(k)") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1)
    }

    func testFallbackPlaceholdersAndCp437() {
        _ = shell(["en-US"])
        XCTAssertEqual("missing.key.for.test", tr("missing.key.for.test"))
        XCTAssertTrue(L10n.has("button.cancel"))
        // placeholders substitute (an unused one is left out, an unknown one stays as written)
        XCTAssertEqual("x a=1 b=two {c}", L10n.fill("x a={a} b={b} {c}", [("a", 1), ("b", "two")]))
        XCTAssertFalse(tr("toast.saved", ("path", "C:/Home/X.HC")).contains("{path}"))
        XCTAssertTrue(tr("toast.saved", ("path", "C:/Home/X.HC")).contains("C:/Home/X.HC"))
        let s = "é ñ ß Ü"
        XCTAssertTrue(Cp437.representable(s))
        XCTAssertEqual(s, Cp437.decode(Cp437.encode(s)))
        XCTAssertEqual([0x82, 0x20, 0xA4, 0x20, 0xE1, 0x20, 0x9A], Cp437.encode(s).unicodeScalars.map { Int($0.value) })
        XCTAssertFalse(Cp437.representable("日本語"))
        XCTAssertEqual("?", Cp437.encode("日"))
        L10n.use("ja-JP")
        XCTAssertEqual("ja-JP", L10n.locale?.id)
        // a missing key falls back to English in another language too
        XCTAssertEqual("missing.key.for.test", tr("missing.key.for.test"))
        // a Japanese string cannot go into a CP437 console: English instead
        let key = "button.cancel"
        XCTAssertFalse(Cp437.representable(tr(key)))
        XCTAssertEqual(Cp437.encode(L10n.tr8(key)), L10n.tr8(key))
        XCTAssertTrue(Cp437.representable(L10n.tr8(key)))
        L10n.use("en-US")
        let english = tr(key)
        L10n.use("ja-JP")
        XCTAssertEqual(english, L10n.tr8(key))
        L10n.use("de-DE")
        XCTAssertTrue(Cp437.representable(L10n.tr8(key)))
    }

    func testFsErrorLocalized() {
        _ = shell(["en-US"])
        let e = FsError("File not found: C:/X", "fs.error.not_found", ["path": "C:/X"])
        XCTAssertTrue(e.localized().contains("C:/X"))
        XCTAssertFalse(e.localized().contains("{path}"))
        XCTAssertEqual("plain", FsError("plain").localized())
        XCTAssertEqual("plain", FsError("plain", "no.such.key").localized())
    }

    func testSettingsLanguageEncoding() {
        let st = Settings()
        st.language = "pt-BR"
        XCTAssertTrue(st.encode().contains(";g=pt-BR"))
        // the engine setting (Pure Terry / Pure Swift) round-trips and defaults to Pure Terry
        XCTAssertEqual(Settings.ENGINE_TERRY, Settings.decode("d=8;s=1").engine)
        st.engine = Settings.ENGINE_NATIVE
        XCTAssertEqual(Settings.ENGINE_NATIVE, Settings.decode(st.encode()).engine)
        XCTAssertEqual("pt-BR", Settings.decode(st.encode()).language)
        XCTAssertEqual("", Settings.decode("d=8;s=1").language)
        XCTAssertEqual("zh-Hans", Settings.decode("g=zh-Hans;x").language)
        XCTAssertEqual("deDE", Settings.decode("g=de_DE!").language)
    }

    func testDeviceLanguageAndManualOverride() {
        let (sh, env) = shell(["cy-GB", "ja-JP"], "JP")
        XCTAssertEqual("ja-JP", L10n.locale?.id)
        let settings = SettingsApp(sh); sh.open(settings); _ = sh.tick()
        let windows = sh.windows.count
        let jaTitle = settings.title
        // manual choice wins over the device and keeps every window
        sh.settings.language = "de-DE"; sh.applyLanguage(); _ = sh.tick()
        XCTAssertEqual("de-DE", L10n.locale?.id)
        XCTAssertEqual(windows, sh.windows.count)
        XCTAssertTrue(sh.windows.contains { $0.app === settings })
        XCTAssertNotEqual(jaTitle, settings.title)
        XCTAssertGreaterThan(L10n.version, 0)
        // persisted, restored
        sh.saveSession()
        L10n.use("en-US")
        let sh2 = Shell(env); sh2.resize(320, 480); sh2.restoreSession(); _ = sh2.tick()
        XCTAssertEqual("de-DE", sh2.settings.language)
        XCTAssertEqual("de-DE", L10n.locale?.id)
        // "Automatic" restores the device language
        sh2.settings.language = ""; sh2.applyLanguage()
        XCTAssertEqual("ja-JP", L10n.locale?.id)
        // device language changes while running
        env.langs = ["fr-CA"]; sh2.applyLanguage()
        XCTAssertEqual("fr-CA", L10n.locale?.id)
        env.langs = ["fr"]; env.region = "CA"; sh2.applyLanguage()
        XCTAssertEqual("fr-CA", L10n.locale?.id)
        env.langs = []; sh2.applyLanguage()
        XCTAssertEqual("en-US", L10n.locale?.id)
    }

    func testLanguageAppSwitchKeepsWindows() {
        let (sh, _) = shell(["en-US"])
        Launch.terminal(sh); _ = sh.tick()
        Launch.language(sh); _ = sh.tick()
        let n = sh.windows.count
        XCTAssertEqual(2, n)
        let lang = sh.focused!.app as! LanguageApp
        // type a filter, then tap the first row (rows are laid out by draw)
        lang.text("de-de"); _ = sh.tick()
        let client = sh.clientRect(sh.focused!)
        lang.tap(client.x + 20, client.y + 4 + ROW_H + 4 + ROW_H / 2, client)
        _ = sh.tick()
        XCTAssertEqual("de-DE", sh.settings.language)
        XCTAssertEqual("de-DE", L10n.locale?.id)
        XCTAssertEqual(n, sh.windows.count)
        XCTAssertTrue(sh.focused?.app === lang)
    }

    func testTextRunsForScriptsOutsideTheFont() {
        let (sh, _) = shell(["ja-JP"])
        // The required intro is locale-independent; exercise translated settings instead.
        Launch.settings(sh); sh.invalidate(); _ = sh.tick()
        let s = sh.surface
        XCTAssertFalse(s.runs.isEmpty, "Japanese UI text is drawn by the platform")
        for r in s.runs {
            XCTAssertFalse(Cp437.representable(r.text))
            XCTAssertTrue(r.clip.w > 0 && r.clip.h > 0)
            XCTAssertTrue(r.clip.x >= 0 && r.clip.right <= s.width && r.clip.y >= 0 && r.clip.bottom <= s.height)
        }
        // a window drawn later hides earlier text runs under it
        Launch.terminal(sh); _ = sh.tick()
        XCTAssertFalse(s.occluders.isEmpty)
        XCTAssertTrue(s.runs.contains { r in s.occluders.contains { $0.z > r.z } })
        // German fits the TempleOS font: no platform text at all on the desktop
        L10n.use("de-DE"); sh.invalidate(); _ = sh.tick()
        XCTAssertTrue(s.runs.allSatisfy { !Cp437.representable($0.text) })
    }

    func testRightToLeft() {
        _ = shell(["ar-EG"], "EG")
        XCTAssertEqual("ar", L10n.locale?.id)
        XCTAssertTrue(L10n.rtl)
        L10n.use("he-IL"); XCTAssertTrue(L10n.rtl)
        L10n.use("en-US"); XCTAssertFalse(L10n.rtl)
    }
}
