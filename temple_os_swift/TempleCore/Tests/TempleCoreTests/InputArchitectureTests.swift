import Foundation
import XCTest
@testable import TempleCore

final class InputArchitectureTests: XCTestCase {
    private var dir: URL!
    private var sh: Shell!
    private final class Target: App {
        override var title: String { "input-probe" }
        override var kind: String { "probe" }
        override var wantsKeyboard: Bool { true }
        override var rawKeys: Bool { true }
        var events: [(Int, Int64, Bool)] = []
        override func draw(_ s: Surface, _ r: Rect) {}
        override func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool { events.append((ch, sc, down)); return true }
    }
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh = Shell(HeadlessEnv(dir)); sh.resize(390, 844, 47, 34)
    }
    override func tearDown() {
        sh.settings.language = "en-US"; sh.applyLanguage()
        for w in sh.windows { sh.close(w, force: true) }
        sh = nil; try? FileManager.default.removeItem(at: dir)
    }
    func testLosslessCP437AndAtomicUnicodeRejection() {
        XCTAssertEqual(InputCharacterPolicy.encode("éñß"), String(String.UnicodeScalarView([130,164,225].map { Unicode.Scalar($0)! })))
        XCTAssertEqual(InputCharacterPolicy.encode("e\u{301}\r\nx"), "\u{82}\nx")
        for s in ["ok🙂", "東京", "a\u{0}b", "a\u{1B}b", "ع"] { XCTAssertNil(InputCharacterPolicy.encode(s)) }
        let large = String(repeating: "I64 x=1;\n", count: 10_000)
        XCTAssertEqual(InputCharacterPolicy.encode(large), large)
        XCTAssertNil(InputCharacterPolicy.encode(large + "🙂"))
        XCTAssertNil(InputCharacterPolicy.encode("a\nb", singleLine: true))
        XCTAssertEqual(InputCharacterPolicy.encode("C:/Home/Test.HC", singleLine: true), "C:/Home/Test.HC")
        for b in 128...255 {
            let byte = String(Unicode.Scalar(b)!)
            XCTAssertEqual(InputCharacterPolicy.encode(Cp437.decode(byte)), byte, "CP437 \(b)")
        }
    }
    func testPasteValidatesBeforeChangingEditorOrSelection() {
        let ed = EditorApp(sh, nil, "keep"); sh.open(ed)
        XCTAssertFalse(sh.insertUnicodeText("bad🙂")); XCTAssertEqual(ed.text(), "keep")
        ed.insert("bad東京"); XCTAssertEqual(ed.text(), "keep")
        XCTAssertTrue(sh.insertUnicodeText("é")); XCTAssertTrue(ed.text().contains("\u{82}"))
        XCTAssertEqual(sh.rejectedInputCount, 2)
    }
    func testLegacyUnicodeDraftNeverSilentlySavesOrRuns() {
        let draft = "東京🙂"
        let ed = EditorApp(sh, "C:/Home/Legacy.HC", draft); sh.open(ed); _ = sh.tick()
        XCTAssertEqual(ed.text(), draft)
        XCTAssertFalse(ed.save()); ed.run()
        XCTAssertFalse(sh.fs.exists("C:/Home/Legacy.HC"))
        XCTAssertEqual(sh.windows.count, 1)
        XCTAssertEqual(InputCharacterPolicy.display(draft), draft)
    }
    func testPasteIsDataWhileShortcutModifierIsLatched() {
        let ed = EditorApp(sh, nil, "keep"); sh.open(ed)
        sh.toggleCtrl()
        XCTAssertTrue(sh.insertUnicodeText("abc"))
        XCTAssertTrue(ed.text().contains("abc")); XCTAssertTrue(ed.text().contains("keep"))
        XCTAssertFalse(sh.ctrlLatched)
    }
    func testOriginalControlBytesAndBinaryTailRoundTrip() throws {
        let bytes = latin1("//\u{1F}\u{80}\n\"OK\";") + [0, 22, 33]
        try sh.fs.writeFile("C:/Home/Bytes.HC", bytes)
        let ed = EditorApp(sh, "C:/Home/Bytes.HC"); sh.open(ed)
        XCTAssertTrue(ed.save()); XCTAssertEqual(sh.fs.readFile("C:/Home/Bytes.HC"), bytes)
        XCTAssertFalse(sh.insertUnicodeText("bad\u{1F}"))
    }
    func testStaleLeaseAndClosedWindowCannotAcquireInput() {
        let a = EditorApp(sh, nil, "a"); let aw = sh.open(a); let lease = sh.inputLease
        let b = EditorApp(sh, nil, "b"); sh.open(b)
        XCTAssertFalse(sh.insertUnicodeText("x", lease: lease)); XCTAssertEqual(b.text(), "b")
        sh.close(aw, force: true); sh.focus(aw)
        XCTAssertTrue(sh.focused?.app === b)
    }
    func testHeldKeysAndModifiersReleaseBeforeFocusAndIgnoreLateUp() {
        let a = Target(sh); sh.open(a)
        let pair = Keys.forChar(97)
        sh.hardwareKey(pair.0, pair.1, true)
        sh.hardwareKey(0, Int64(Keys.SC_CTRL) | Keys.SCF_CTRL, true)
        let b = Target(sh); sh.open(b)
        XCTAssertEqual(a.events.filter { !$0.2 }.count, 2)
        sh.hardwareKey(pair.0, pair.1, false); sh.hardwareKey(0, Int64(Keys.SC_CTRL), false)
        XCTAssertTrue(b.events.isEmpty)
    }
    func testDedicatedHardwareKeypadRemainsNumeric() {
        for hid in 89...97 { XCTAssertEqual(PhysicalKeyMap.hid(hid)?.0, 49 + hid - 89) }
        XCTAssertEqual(PhysicalKeyMap.hid(98)?.0, 48)
        XCTAssertEqual(PhysicalKeyMap.hid(99)?.0, 46)
        XCTAssertNil(PhysicalKeyMap.hid(70)); XCTAssertNil(PhysicalKeyMap.hid(72))
    }
    func testMenuTransitionReleasesOldProgramBeforeIntercepting() {
        let a = Target(sh); sh.open(a)
        sh.hardwareKey(0, Int64(Keys.SC_CURSOR_UP), true)
        sh.showStartMenu()
        XCTAssertEqual(a.events.count, 2); XCTAssertFalse(a.events.last!.2)
        sh.hardwareKey(0, Int64(Keys.SC_CURSOR_UP), false)
        XCTAssertEqual(a.events.count, 2)
        sh.hardwareKey(0, Int64(Keys.SC_CTRL) | Keys.SCF_CTRL, true)
        sh.hardwareKey(0, Int64(Keys.SC_CTRL), false)
        XCTAssertEqual(a.events.count, 2, "menu owns modifiers too")
    }
    func testBackgroundCancelsTouchRepeatAndRetainsKeyboardIntent() {
        let ed = EditorApp(sh, nil, ""); sh.open(ed); _ = sh.tick()
        let key = sh.accessibilityNodes().first { $0.label == "a" }!
        let x = key.rect.x + 2, y = key.rect.y + 2
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: 88, timeMs: 100))
        sh.onBackground(); sh.onForeground()
        sh.pointer(PointerEvent(Ptr.UP, x, y, id: 88, timeMs: 200)); _ = sh.tick()
        XCTAssertEqual(ed.text(), ""); XCTAssertTrue(sh.templeKeyboardShown)
        sh.hideKeyboard(); sh.onBackground(); sh.onForeground()
        XCTAssertFalse(sh.templeKeyboardShown); sh.requestKeyboard(); XCTAssertTrue(sh.templeKeyboardShown)
    }
    func testModalPasteIsSingleLineAndCannotEscapeToUnderlyingWindow() {
        let ed = EditorApp(sh, nil, "keep"); sh.open(ed)
        var answer: String?
        sh.showDialog(Dialog.input("Path", "") { answer = $0 })
        XCTAssertFalse(sh.insertUnicodeText("bad\ncommand")); XCTAssertEqual(ed.text(), "keep")
        XCTAssertTrue(sh.insertUnicodeText("é")); sh.text("\n")
        XCTAssertEqual(answer, "\u{82}"); XCTAssertEqual(ed.text(), "keep")
    }
    func testPopupRejectsReleaseFromKeyboardOrPreviousDialog() {
        sh.open(EditorApp(sh, nil, "keep")); _ = sh.tick()
        let key = sh.accessibilityNodes().first { $0.label == "a" }!.rect
        sh.pointer(PointerEvent(Ptr.DOWN, key.x+2, key.y+2, id: 88))
        var picked = 0
        let first = Dialog.choose("First", "", [("Pick once", 1)], []) { if $0 == 1 { picked += 1 } }
        first.onCancel = {}
        sh.showDialog(first); _ = sh.tick()
        var row = sh.accessibilityNodes().first { $0.label == "Pick once" }!.rect
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, id: 88))
        XCTAssertEqual(picked, 0); XCTAssertTrue(sh.dialogOpen)
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, id: 89))
        sh.showDialog(Dialog.choose("Second", "", [("Pick once", 1)], []) { if $0 == 1 { picked += 1 } })
        _ = sh.tick(); row = sh.accessibilityNodes().first { $0.label == "Pick once" }!.rect
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, id: 89))
        XCTAssertEqual(picked, 0); XCTAssertTrue(sh.dialogOpen)
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, id: 90))
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, id: 91))
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, id: 91))
        XCTAssertEqual(picked, 0)
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, id: 90))
        XCTAssertEqual(picked, 1); XCTAssertFalse(sh.dialogOpen)
    }
    func testPopupRejectsReleaseAcrossBackgroundAndMenuChange() {
        var picked = 0
        sh.showDialog(Dialog.choose("Choice", "", [("Pick once", 1)], []) { if $0 == 1 { picked += 1 } }); _ = sh.tick()
        let row = sh.accessibilityNodes().first { $0.label == "Pick once" }!.rect
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, id: 92))
        sh.onBackground(); sh.onForeground()
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, id: 92))
        XCTAssertEqual(picked, 0)
        sh.showMenu([MenuItem("Menu pick", { picked += 1 })], 10, 80); _ = sh.back(); _ = sh.tick()
        let menuRow = sh.accessibilityNodes().first { $0.label == "Menu pick" }!.rect
        sh.pointer(PointerEvent(Ptr.UP, menuRow.x+2, menuRow.y+2, id: 92))
        XCTAssertEqual(picked, 0)
        sh.pointer(PointerEvent(Ptr.DOWN, menuRow.x+2, menuRow.y+2, id: 93))
        sh.pointer(PointerEvent(Ptr.UP, menuRow.x+2, menuRow.y+2, id: 93))
        XCTAssertEqual(picked, 1)
    }
    func testExtendedPickerRestoresDialogTarget() {
        sh.open(EditorApp(sh, nil, "keep"))
        var answer: String?
        sh.showDialog(Dialog.input("Path", "") { answer = $0 })
        sh.showCharacterPicker(); sh.text("\n"); _ = sh.tick()
        XCTAssertEqual(sh.inputTarget, "dialog")
        sh.text("\n"); XCTAssertEqual(answer, "\u{80}")
    }
    func testHundredTargetCloseCyclesAndRapidGeometryTransitions() {
        for i in 0..<100 {
            let a = EditorApp(sh, nil, ""); let aw = sh.open(a); let lease = sh.inputLease
            sh.text("x"); XCTAssertEqual(a.text(), "x")
            sh.resize(i % 2 == 0 ? 844 : 390, i % 2 == 0 ? 390 : 844, 20, 20, 0, 0, 300)
            sh.hardwareKeyUsed(); XCTAssertTrue(sh.templeKeyboardShown)
            sh.close(aw, force: true)
            XCTAssertFalse(sh.insertUnicodeText("late", lease: lease))
            XCTAssertEqual(sh.inputTarget, "none"); XCTAssertEqual(sh.keyboardHeight, 0)
        }
    }
    func testHundredRealTerminalLaunchTypeExecuteCloseCycles() {
        for _ in 0..<100 {
            autoreleasepool {
                Launch.terminal(sh)
                let window = sh.focused!, terminal = window.app as! TerminalApp
                let ready = Date().addingTimeInterval(10)
                while !terminal.kernel.console.plainText().contains(">") && Date() < ready { Thread.sleep(forTimeInterval: 0.002) }
                Thread.sleep(forTimeInterval: 0.002)
                sh.text("6*7;\n")
                let end = Date().addingTimeInterval(5)
                while !terminal.kernel.console.plainText().contains("ans=0x0000002A=42") && Date() < end { Thread.sleep(forTimeInterval: 0.002) }
                XCTAssertTrue(terminal.kernel.console.plainText().contains("ans=0x0000002A=42"))
                sh.close(window, force: true); _ = sh.tick()
                XCTAssertEqual(sh.inputTarget, "none")
            }
        }
    }
    func testTouchClockCannotCauseImmediateRepeat() {
        let ed = EditorApp(sh, nil, ""); sh.open(ed); _ = sh.tick()
        let n = sh.accessibilityNodes().first { $0.label == "a" }!
        sh.pointer(PointerEvent(Ptr.DOWN, n.rect.x+2, n.rect.y+2, id: 72, timeMs: 1))
        _ = sh.tick(); XCTAssertEqual(ed.text(), "")
        sh.pointer(PointerEvent(Ptr.UP, n.rect.x+2, n.rect.y+2, id: 72, timeMs: 2))
        XCTAssertEqual(ed.text(), "a")
    }
    func testHeldTextKeyRetainsItsModifierSnapshot() {
        let ed = EditorApp(sh, nil, "keep"); sh.open(ed); _ = sh.tick()
        sh.toggleCtrl()
        let n = sh.accessibilityNodes().first { $0.label == "a" }!, time = sh.env.nowMs()
        sh.keyboard.pointer(PointerEvent(Ptr.DOWN, n.rect.x+2, n.rect.y+2, id: 73), time)
        _ = sh.keyboard.tick(time+401); _ = sh.keyboard.tick(time+470)
        sh.keyboard.pointer(PointerEvent(Ptr.UP, n.rect.x+2, n.rect.y+2, id: 73), time+480)
        XCTAssertEqual(ed.text(), "keep", "Ctrl-A repeats must not turn into plain 'a'")
        sh.text("x"); XCTAssertEqual(ed.text(), "x")
    }
    func testPhysicalMappingsUseTempleOSTablesIncludingCapsDigits() {
        for n in 0..<26 {
            XCTAssertEqual(PhysicalKeyMap.hid(4+n)!.0, 97+n)
            XCTAssertEqual(PhysicalKeyMap.hid(4+n, shift: true)!.0, 65+n)
            XCTAssertEqual(PhysicalKeyMap.hid(4+n, ctrl: true)!.0, 1+n)
        }
        XCTAssertEqual(PhysicalKeyMap.hid(30, caps: true)!.0, 33)
        XCTAssertEqual(PhysicalKeyMap.hid(44, shift: true)!.0, Keys.CH_SHIFT_SPACE)
        XCTAssertEqual(PhysicalKeyMap.hid(41, shift: true)!.0, Keys.CH_SHIFT_ESC)
        XCTAssertEqual(PhysicalKeyMap.hid(82)!.1 & 255, Int64(Keys.SC_CURSOR_UP))
        XCTAssertNil(PhysicalKeyMap.hid(1000))
    }
    func testKeyboardLayoutAndLocalizedDisplayAreIndependent() {
        let ed = EditorApp(sh, nil, ""); sh.open(ed)
        let initial = sh.keyboard.rows().flatMap { $0 }.compactMap(\.ch)
        for language in ["en-US", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-CN", "ar-SA"] {
            sh.settings.language = language; sh.applyLanguage(); _ = sh.tick()
            XCTAssertEqual(sh.keyboard.rows().flatMap { $0 }.compactMap(\.ch), initial)
            XCTAssertTrue(sh.insertUnicodeText("I64 x=1;")); XCTAssertTrue(sh.templeKeyboardShown)
        }
        XCTAssertEqual(InputCharacterPolicy.display("日本語 العربية 🙂"), "日本語 العربية 🙂")
    }
}
