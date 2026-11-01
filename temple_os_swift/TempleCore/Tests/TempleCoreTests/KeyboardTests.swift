import Foundation
import XCTest
@testable import TempleCore

/**
 * The in-app TempleOS keyboard (port of KeyboardTest.kt), driven the way a screen reader does
 * it (activating the accessibility nodes the shell publishes), so both are tested together.
 */
final class KeyboardTests: XCTestCase {
    private var dir: URL!
    private var env: HeadlessEnv!
    private var sh: Shell!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env = HeadlessEnv(dir)
        sh = Shell(env); sh.resize(360, 780, 24, 16, 0, 0, 0); _ = sh.tick()
    }

    override func tearDown() {
        for w in sh.windows { sh.close(w, force: true) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func node(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> A11yNode {
        sh.invalidate(); _ = sh.tick()
        guard let n = sh.accessibilityNodes().first(where: { $0.label == label }) else {
            XCTFail("no node '\(label)' in \(sh.accessibilityNodes().map { $0.label })", file: file, line: line)
            throw XCTSkip("missing node")
        }
        return n
    }
    private func press(_ labels: String...) throws { for l in labels { sh.accessibilityActivate(try node(l)) } }

    private func editor(_ text: String) throws -> EditorApp {
        try sh.fs.writeFile("C:/Home/Kbd.HC", latin1(text))
        Launch.editor(sh, "C:/Home/Kbd.HC"); _ = sh.tick()
        return sh.focused!.app as! EditorApp
    }

    func testTextAppsGetTheTempleOsKeyboardNotTheDeviceKeyboard() throws {
        _ = try editor("x")
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertFalse(env.systemKeyboard, "device keyboard stays hidden")
        let kr = sh.keyboardRect()
        XCTAssertLessThanOrEqual(kr.bottom, 780 - 16, "keyboard is above the home indicator")
        XCTAssertLessThanOrEqual(sh.desktopRect().bottom, kr.y, "the window ends above the keyboard")
        let keys = sh.accessibilityNodes().filter { kr.contains($0.rect.x + 1, $0.rect.y + 1) }
        XCTAssertGreaterThanOrEqual(keys.count, 50)
        XCTAssertTrue(keys.allSatisfy { $0.button && $0.rect.h >= 30 })
    }

    func testTypingInsertsAtTheCaretWithShiftSymbolsAndBackspace() throws {
        let ed = try editor("ab")
        ed.restoreCursor(0, 1)
        try press("Shift", "X")                     // one-shot shift; keys now read as capitals
        XCTAssertEqual(ed.text(), "aXb")
        try press("y")
        XCTAssertEqual(ed.text(), "aXyb")
        try press("Backspace")
        XCTAssertEqual(ed.text(), "aXb")
        try press("Symbols", "left brace", "Letters", "semicolon", "quote")
        XCTAssertEqual(ed.text(), "aX{;\"b")
        try press("Function keys")
        XCTAssertEqual(sh.keyboard.layer, TempleKeyboard.FUNCTIONS)
        try press("Home")
        try press("Function keys")
        XCTAssertEqual(sh.keyboard.layer, TempleKeyboard.LETTERS)
        try press("Shift", "Shift")                  // double tap: caps lock
        try press("Q", "W")
        XCTAssertEqual(ed.text(), "QWaX{;\"b")
        XCTAssertEqual(sh.keyboard.shift, 2)
    }

    func testHeldBackspaceRepeats() throws {
        let ed = try editor("abcdefghijklmnopqrstuvwxyz")
        ed.restoreCursor(0, 26)
        let n = try node("Backspace")
        let x = n.rect.x + n.rect.w / 2, y = n.rect.y + n.rect.h / 2
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: 5, timeMs: env.nowMs()))
        let end = Date().addingTimeInterval(0.9)
        while Date() < end { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.01) }
        sh.pointer(PointerEvent(Ptr.UP, x, y, id: 5, timeMs: env.nowMs()))
        XCTAssertGreaterThanOrEqual(26 - ed.text().count, 5, "held backspace repeats")
    }

    func testModifiersResetWhenFocusChanges() throws {
        _ = try editor("x")
        try press("Control")
        XCTAssertTrue(sh.ctrlLatched)
        Launch.settings(sh); _ = sh.tick()
        XCTAssertFalse(sh.ctrlLatched, "Ctrl must not leak into another window")
        XCTAssertFalse(sh.templeKeyboardShown)
    }

    func testLegacyDeviceSettingCannotActivateAPlatformKeyboard() throws {
        _ = try editor("x")
        sh.settings = Settings.decode("k=1")
        sh.setKeyboardMode(1)
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertFalse(env.systemKeyboard)
        XCTAssertEqual(sh.settings.keyboardMode, 0)
        sh.saveSession()
        XCTAssertTrue(env.session!.contains("k=0"))
        XCTAssertFalse(sh.accessibilityNodes().contains { $0.label == "Use the device keyboard" })
    }

    func testHardwareKeyboardKeepsSoftwareInputAvailable() throws {
        _ = try editor("x")
        sh.hardwareKeyUsed()
        XCTAssertTrue(sh.templeKeyboardShown)
        try press("Hide keyboard")
        XCTAssertFalse(sh.templeKeyboardShown)
        try press("Show or hide keyboard")
        XCTAssertTrue(sh.templeKeyboardShown)
    }

    func testTerminalRunsWhatIsTypedOnTheKeyboard() throws {
        Launch.terminal(sh, "C:/Home"); _ = sh.tick()
        let term = sh.focused!.app as! TerminalApp
        XCTAssertTrue(sh.templeKeyboardShown)
        try press("6", "Shift", "asterisk", "7", "semicolon", "Enter") // shift+8
        let end = Date().addingTimeInterval(20)
        while Date() < end && !term.kernel.console.plainText().contains("ans=0x0000002A") { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(term.kernel.console.plainText().contains("ans=0x0000002A=42"), term.kernel.console.plainText().takeLast(300))
    }

    func testSaveAsDialogTakesKeyboardInput() throws {
        let ed = try editor("1;")
        ed.insert("2;")
        Launch.editor(sh, nil); _ = sh.tick()
        let untitled = sh.focused!.app as! EditorApp
        _ = untitled.save()
        XCTAssertTrue(sh.dialogOpen)
        XCTAssertTrue(sh.templeKeyboardShown, "the dialog's text field gets the TempleOS keyboard")
        sh.invalidate(); _ = sh.tick()
        let before = sh.accessibilityNodes().first { $0.label.hasPrefix("Text field") }!.label
        try press("z")
        let after = sh.accessibilityNodes().first { $0.label.hasPrefix("Text field") }!.label
        XCTAssertEqual(after, before + "z")
    }

    func testLandscapeTempleKeyboardDoesNotShrinkFloatingWindows() throws {
        sh.resize(800, 360, 23, 16, 0, 0, 0); _ = sh.tick()
        _ = try editor("x")
        let win = sh.focused!
        XCTAssertTrue(sh.templeKeyboardShown && sh.typingCompact)
        let placed = [win.x, win.y, win.w, win.h]
        XCTAssertGreaterThanOrEqual(win.h, 200, "window placed for the desktop, not the space above the keyboard: \(placed)")
        sh.hideKeyboard(); _ = sh.tick()
        XCTAssertEqual(placed, [win.x, win.y, win.w, win.h])
    }

    func testKeyPressCostIsSmall() throws {
        let ed = try editor("")
        let keys = try "abcdefghij".map { try node(String($0)) }
        for i in 0..<50 { sh.accessibilityActivate(keys[i % 10]); sh.invalidate(); _ = sh.tick() }
        let n = 200
        let t0 = monoNanos()
        for i in 0..<n { sh.accessibilityActivate(keys[i % 10]); sh.invalidate(); _ = sh.tick() }
        let us = (monoNanos() - t0) / 1000 / Int64(n)
        print("KEYPRESS-COST: \(us) us per key press (dispatch + editor + full 360x780 render)")
        XCTAssertEqual(ed.text().count, 250)
        XCTAssertLessThan(us, 20_000)
    }
}
