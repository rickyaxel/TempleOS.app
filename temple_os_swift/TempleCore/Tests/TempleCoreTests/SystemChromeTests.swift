import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of SystemChromeTest.kt: the home indicator / navigation region shows the TempleOS surface that
 * owns the bottom edge. Every check also reads the rendered surface, so the declared appearance and
 * the pixels cannot drift apart.
 */
final class SystemChromeTests: XCTestCase {
    /** A plain app (no override): the shell's defaults apply. */
    private final class PlainApp: App {
        private let k: String, edge: Int?, defer_: Bool
        init(_ shell: Shell, _ kind: String = "plain", edge: Int? = nil, defer: Bool = false) { k = kind; self.edge = edge; defer_ = `defer`; super.init(shell) }
        override var title: String { "Plain" }
        override var kind: String { k }
        override func draw(_ s: Surface, _ r: Rect) { s.fill(r, Palette.CYAN) }
        override var systemEdgeColor: Int? { edge }
        override var defersEdgeGestures: Bool { defer_ }
    }

    private func withShell(_ w: Int = 360, _ h: Int = 800, top: Int = 21, bottom: Int = 21, left: Int = 0, right: Int = 0, _ body: (Shell) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-chrome-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir))
        sh.resize(w, h, top, bottom, left, right, 0)
        _ = sh.tick()
        try body(sh)
        for win in sh.windows { win.app.close() }
    }

    private func px(_ sh: Shell, _ x: Int, _ y: Int) -> Int { Int(sh.surface.px[y * sh.surface.width + x] & 15) }

    private func rowColor(_ sh: Shell, _ y: Int) -> Int {
        var n = [Int](repeating: 0, count: 16)
        for x in sh.insetLeft..<(sh.width - sh.insetRight) { n[px(sh, x, y)] += 1 }
        return n.indices.max { n[$0] < n[$1] }!
    }

    private func assertPainted(_ sh: Shell, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        _ = sh.tick()
        let c = sh.systemChrome
        let usableBottom = sh.height - max(sh.insetBottom, sh.keyboardHeight)
        var wrong = 0
        for y in usableBottom..<sh.height { for x in 0..<sh.width where px(sh, x, y) != c.bottom { wrong += 1 } }
        XCTAssertEqual(wrong, 0, "\(label): bottom gutter pixels not \(c.bottom)", file: file, line: line)
        XCTAssertEqual(rowColor(sh, usableBottom - 1), c.bottom, "\(label): the surface drawn above the system region", file: file, line: line)
        if sh.insetLeft > 0 { XCTAssertEqual(px(sh, 0, sh.height / 2), c.side, "\(label): left gutter", file: file, line: line) }
        if sh.insetRight > 0 { XCTAssertEqual(px(sh, sh.width - 1, sh.height / 2), c.side, "\(label): right gutter", file: file, line: line) }
    }

    func testEmptyDesktopUsesTheDesktopColor() {
        withShell { sh in
            XCTAssertEqual(sh.systemChrome.owner, .desktop)
            XCTAssertEqual(sh.systemChrome.bottom, sh.settings.desktopColor)
            assertPainted(sh, "desktop")
        }
    }

    func testPortraitWindowOwnsTheBottomEdgeWithItsBackground() {
        withShell { sh in
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .window)
            XCTAssertEqual(sh.systemChrome.bottom, Shell.WINDOW_BG)
            assertPainted(sh, "doc window")
            XCTAssertTrue(sh.systemChrome.darkIconsAt(.bottom))
        }
    }

    func testScreenChangesUpdateAndRestoreTheAppearance() {
        withShell { sh in
            let before = sh.systemChrome
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            let doc = sh.systemChrome
            XCTAssertNotEqual(before, doc)
            Launch.terminal(sh); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .keyboard)
            XCTAssertEqual(sh.systemChrome.bottom, Shell.BAR_BG)
            XCTAssertFalse(sh.systemChrome.darkIconsAt(.bottom))
            assertPainted(sh, "terminal + TempleOS keyboard")
            sh.hideKeyboard(); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .keyRow)
            assertPainted(sh, "terminal + key row")
            sh.close(sh.focused!); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome, doc, "back on the document")
            assertPainted(sh, "doc again")
            sh.close(sh.focused!); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome, before, "back on the empty desktop")
        }
    }

    func testMenusAndDialogsDoNotTakeTheBottomEdge() {
        withShell { sh in
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            let doc = sh.systemChrome
            sh.showStartMenu(); _ = sh.tick()
            XCTAssertTrue(sh.popupOpen)
            XCTAssertEqual(sh.systemChrome, doc, "start menu")
            assertPainted(sh, "start menu")
            _ = sh.back(); _ = sh.tick()
            sh.showDialog(Dialog.confirm("Title", "A long message that wraps over a few lines.", "OK") {}); _ = sh.tick()
            XCTAssertTrue(sh.dialogOpen)
            XCTAssertEqual(sh.systemChrome, doc, "dialog")
            assertPainted(sh, "dialog")
            _ = sh.back(); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome, doc)
        }
    }

    func testAFullWidthSheetReachingTheBottomOwnsIt() {
        let window = SystemChrome.Layer(Rect(0, 40, 360, 739), Palette.WHITE, .window)
        let dialog = SystemChrome.Layer(Rect(20, 200, 320, 200), Palette.WHITE, .popup)
        let sheet = SystemChrome.Layer(Rect(0, 500, 360, 279), Palette.BLUE, .popup)
        let shortSheet = SystemChrome.Layer(Rect(0, 500, 360, 270), Palette.BLUE, .popup)
        let narrow = SystemChrome.Layer(Rect(4, 500, 352, 279), Palette.BLUE, .popup)
        func r(_ bars: SystemChrome.Layer...) -> SystemChrome {
            SystemChrome.resolve(desktop: Palette.DKGRAY, content: [window], contentBottom: 779, bars: bars, usableBottom: 779, left: 0, right: 360)
        }
        XCTAssertEqual(r(dialog).owner, .window)
        XCTAssertEqual(r(dialog).bottom, Palette.WHITE)
        XCTAssertEqual(r(dialog, sheet).owner, .popup)
        XCTAssertEqual(r(dialog, sheet).bottom, Palette.BLUE)
        XCTAssertEqual(r(sheet).side, Palette.WHITE, "the side gutters still follow the content")
        XCTAssertEqual(r(shortSheet).owner, .window)
        XCTAssertEqual(r(narrow).owner, .window)
    }

    func testNativeKeyboardGeometryCannotChangeTheApp() {
        withShell { sh in
            sh.setKeyboardMode(Settings.KEYBOARD_SYSTEM)
            Launch.editor(sh, "C:/Home/Examples/Hello.HC"); _ = sh.tick()
            XCTAssertFalse(sh.systemChrome.deviceKeyboard)
            XCTAssertEqual(sh.systemChrome.owner, .keyboard)
            sh.resize(360, 800, 21, 21, 0, 0, 300); _ = sh.tick()
            XCTAssertFalse(sh.systemChrome.deviceKeyboard)
            XCTAssertEqual(sh.systemChrome.owner, .keyboard)
            assertPainted(sh, "device keyboard")
            sh.resize(360, 800, 21, 21, 0, 0, 0); _ = sh.tick()
            XCTAssertFalse(sh.systemChrome.deviceKeyboard)
            assertPainted(sh, "device keyboard closed")
        }
    }

    func testUnchangedAppearanceIsAppliedOnce() {
        withShell { sh in
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            var applied: [SystemChrome] = []
            let gate = ChangeGate<SystemChrome> { applied.append($0) }
            for _ in 0..<5 { sh.invalidate(); _ = sh.tick(); gate.offer(sh.systemChrome) }
            XCTAssertEqual(applied.count, 1, "five renders of the same screen")
            sh.showStartMenu(); _ = sh.tick(); gate.offer(sh.systemChrome)
            XCTAssertEqual(applied.count, 1, "a menu does not change it")
            _ = sh.back(); Launch.terminal(sh); _ = sh.tick(); gate.offer(sh.systemChrome)
            XCTAssertEqual(applied.count, 2)
            gate.reset(); gate.offer(sh.systemChrome)
            XCTAssertEqual(applied.count, 3, "reset applies again")
        }
    }

    func testIconContrastIsReadableOnEveryPaletteColor() {
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        for c in 0..<16 {
            let l = SystemChrome.luminance(Palette.STD[c])
            let icon = SystemChrome.prefersDarkIcons(c) ? 0.0 : 1.0
            XCTAssertGreaterThanOrEqual(contrast(l, icon), 4.5, "color \(c)")
        }
        XCTAssertTrue(SystemChrome.prefersDarkIcons(Palette.WHITE))
        XCTAssertTrue(SystemChrome.prefersDarkIcons(Palette.LTGRAY))
        XCTAssertFalse(SystemChrome.prefersDarkIcons(Palette.BLACK))
        XCTAssertFalse(SystemChrome.prefersDarkIcons(Palette.BLUE))
        XCTAssertFalse(SystemChrome.prefersDarkIcons(Palette.DKGRAY))
    }

    func testAppsInheritTheWindowDefaultAndMayOverride() {
        withShell { sh in
            _ = sh.open(PlainApp(sh)); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.bottom, Shell.WINDOW_BG)
            XCTAssertFalse(sh.systemChrome.defersEdgeGestures)
            _ = sh.open(PlainApp(sh, "override", edge: Palette.BLACK, defer: true)); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .appOverride)
            XCTAssertEqual(sh.systemChrome.bottom, Palette.BLACK)
            XCTAssertTrue(sh.systemChrome.defersEdgeGestures)
            for x in 0..<sh.width { XCTAssertEqual(px(sh, x, sh.height - 1), Palette.BLACK) }
        }
    }

    func testDesktopColorChangeWithoutNavigationIsFollowed() {
        withShell { sh in
            sh.settings.desktopColor = Palette.BLUE; sh.invalidate(); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.bottom, Palette.BLUE)
            assertPainted(sh, "blue desktop")
        }
    }

    func testLandscapeFloatingWindowsLeaveTheDesktopAndMaximizedWindowsTakeIt() {
        withShell(800, 360, top: 0, bottom: 16, left: 40, right: 42) { sh in
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .desktop, "floating window")
            assertPainted(sh, "landscape floating")
            sh.focused!.maximized = true; sh.relayout(); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .window, "maximized window")
            XCTAssertEqual(sh.systemChrome.side, Shell.WINDOW_BG)
            assertPainted(sh, "landscape maximized")
            XCTAssertEqual(sh.systemChrome.colorAt(.right), Shell.WINDOW_BG)
        }
    }

    func testRotationKeepsTheGuttersPainted() {
        withShell { sh in
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
            sh.resize(800, 360, 0, 16, 40, 42, 0); _ = sh.tick()
            assertPainted(sh, "landscape")
            sh.resize(360, 800, 21, 42, 0, 0, 0); _ = sh.tick()
            XCTAssertEqual(sh.systemChrome.owner, .window)
            assertPainted(sh, "portrait again")
        }
    }
}
