import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of BrandTest.kt (README, "Names"): TempleOS.app wherever the apps name themselves, in every
 * language, never translated; "TempleOS" alone (Terry A. Davis' operating system) untouched.
 */
final class BrandTests: XCTestCase {
    private let repo = SHARED.deletingLastPathComponent()
    private var dirs: [URL] = []
    private var shells: [Shell] = [] // apps hold their shell unowned

    private func text(_ path: String) -> String { try! String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }
    private func hasOld(_ s: String) -> Bool { s.range(of: "TempleOS[ -]?Mobile", options: [.regularExpression, .caseInsensitive]) != nil }

    private func shell() -> Shell {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-brand-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        let sh = Shell(LangEnv(HeadlessEnv(u), ["en-US"])); sh.resize(320, 480); sh.restoreSession(); _ = sh.tick()
        shells.append(sh)
        return sh
    }

    override func tearDown() {
        L10n.use("en-US")
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll(); shells.removeAll()
        super.tearDown()
    }

    func testOneNameEverywhereItIsConfigured() throws {
        XCTAssertEqual("TempleOS.app", Brand.appName)
        let m = try Json.parse(text("shared/runtime/l10n/locales.json")) as! [String: Any?]
        XCTAssertEqual(Brand.appName, m["app_name"] as? String, "manifest app_name")
        let plist = try PropertyListSerialization.propertyList(from: Data(text("temple_os_swift/App/TempleOSMobile/Info.plist").utf8), format: nil) as! [String: Any]
        XCTAssertEqual(Brand.appName, plist["CFBundleDisplayName"] as? String)
        // identities stay as they were
        XCTAssertEqual("$(PRODUCT_NAME)", plist["CFBundleName"] as? String)
        XCTAssertTrue(text("tools/xcode/gen_xcodeproj.py").contains("io.github.templeosmobile"))
        XCTAssertTrue(text("temple_os_kotlin/app/src/main/res/values/strings.xml").contains("<string name=\"app_name\" translatable=\"false\">\(Brand.appName)</string>"))
    }

    func testEveryLanguageShowsTheNameUntranslated() {
        _ = shell()
        let keys = ["fs.error.storage_full", "about.additions.words", "about.credits.native", "catalog.license.project",
                    "doc.link_symbol_unsupported", "doc.notice.mobile.title", "doc.notice.mobile.body"]
        for l in L10n.resolver!.locales {
            L10n.use(l.id)
            for k in keys {
                let t = tr(k, ("mib", 64), ("target", "x"))
                XCTAssertTrue(t.contains(Brand.appName), "\(l.id) \(k): \(t)")
                XCTAssertFalse(t.contains("{app}") || hasOld(t), "\(l.id) \(k): \(t)")
            }
            XCTAssertTrue(tr("about.credits.templeos").contains("TempleOS"), l.id)
        }
        L10n.use("ja-JP")
        XCTAssertEqual("Storage full: \(Brand.appName) keeps at most 64 MiB of your files", L10n.tr8("fs.error.storage_full", ("mib", 64)))
    }

    func testTheAppsNameThemselves() {
        let sh = shell()
        Launch.about(sh); sh.invalidate(); _ = sh.tick()
        let about = sh.accessibilityNodes().filter { !$0.button }.map(\.label).joined(separator: "\n")
        XCTAssertTrue(about.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Brand.appName), about)
        XCTAssertTrue(about.contains("Terry A. Davis"))
        XCTAssertFalse(hasOld(about), about)
        XCTAssertTrue(about.contains(Brand.privacyURL), "About links the privacy policy (App Store 5.1.1(i), Play User Data): \(about)")
        Launch.terminal(sh)
        let term = sh.focused!.app as! TerminalApp
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !(term.kernel?.console.plainText().contains("Terminal") ?? false) { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.02) }
        let banner = term.kernel.console.plainText()
        XCTAssertTrue(banner.contains("\(Brand.appName) Terminal"), banner)
        XCTAssertFalse(hasOld(banner), banner)
    }

    func testProgramsSeeTheName() throws {
        let out = try runHolyC(latin1("\"[%s]\\n\",SysPlatformName;\"[%s]\\n\",sys_mobile_platform;MemBIOSRep;\n")).console.plainText()
        XCTAssertTrue(out.contains("[\(Brand.appName)]\n[\(Brand.appName)]"), out)
        XCTAssertTrue(out.contains("BIOS memory map: not available in \(Brand.appName)."), out)
        let asm = try runHolyC(latin1("asm {NOP}\n")).console.plainText()
        XCTAssertTrue(asm.contains("not supported by \(Brand.appName)"), asm)
    }
}
