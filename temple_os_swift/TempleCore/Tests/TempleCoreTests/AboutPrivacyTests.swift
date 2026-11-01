import Foundation
import XCTest
@testable import TempleCore

private final class PrivacyActionEnv: ShellEnv {
    let base: HeadlessEnv
    var opened = 0
    init(_ base: HeadlessEnv) { self.base = base }
    var fs: LayeredFs { base.fs }
    var stateStore: StateStore { base.stateStore }
    func runtimeFile(_ name: String) -> [UInt8]? { base.runtimeFile(name) }
    func openPrivacyPolicy() { opened += 1 }
}

final class AboutPrivacyTests: XCTestCase {
    func testPrivacyIsAnAccessibleActionThatStaysVisibleAfterScrollingAndResizing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("about-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { L10n.use("en-US"); try? FileManager.default.removeItem(at: dir) }
        let env = PrivacyActionEnv(HeadlessEnv(dir))
        let sh = Shell(env)
        sh.resize(320, 480); sh.restoreSession()
        Launch.about(sh); _ = sh.tick()
        let app = sh.focused!.app
        let rect = Rect(0, 0, 640, 480)
        app.tap(-1, -1, rect)
        XCTAssertEqual(env.opened, 0, "unrelated taps never open the browser")
        for (w, h) in [(320, 480), (640, 360)] {
            sh.resize(w, h); app.scroll(0, -10000, rect); _ = sh.tick()
            let buttons = sh.accessibilityNodes().filter { $0.button && $0.label.contains(Brand.privacyURL) }
            XCTAssertEqual(buttons.count, 1)
            let button = try XCTUnwrap(buttons.first)
            XCTAssertTrue(button.label.contains(tr("about.privacy.title")))
            XCTAssertTrue(button.rect.w > 0 && button.rect.h > 0)
            app.tap(button.rect.x + button.rect.w / 2, button.rect.y + button.rect.h / 2, rect)
        }
        XCTAssertEqual(env.opened, 2, "each explicit activation invokes the fixed platform action once")
    }
}
