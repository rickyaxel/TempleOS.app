import Foundation
import XCTest
@testable import TempleCore

/**
 * Keyboards for a running program (docs/fidelity-audit FA-21, FA-22): physical keys and the
 * on-screen TempleOS keyboard behave like a PC keyboard under TempleOS (Kernel/SerialDev/Keyboard.HC):
 * a key stays down until released, repeats at KbdTypeMatic(0)'s rate (250 ms, then 30/s), SHIFT/CTRL
 * are keys of their own, and SHIFT-ESC can be typed. Port of KeyboardFidelityTest.kt.
 */
final class KeyboardFidelityTests: XCTestCase {
    private let probe = "I64 n=0,last=0,ch,sc;\nwhile (TRUE) {while (ScanKey(&ch,&sc)) {last=ch; if (ch=='a') n++;} Refresh;}\n"

    private final class Run {
        let sh: Shell, k: Kernel, app: ProgramApp, dir: URL
        init(_ sh: Shell, _ k: Kernel, _ app: ProgramApp, _ dir: URL) { self.sh = sh; self.k = k; self.app = app; self.dir = dir }
        @discardableResult func waitFor(_ s: Double, _ c: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(s)
            while Date() < end { _ = sh.tick(); if c() { return true }; Thread.sleep(forTimeInterval: 0.01) }
            _ = sh.tick(); return c()
        }
        func g(_ n: String) -> Int64 { k.mem.ld8((k.prog.globals[n] as! GlobalSym).addr) }
        func bit(_ b: Int) -> Bool { let a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", "down_bitmap"); return (k.mem.ld1(a + (b >> 3)) >> Int64(b & 7)) & 1 != 0 }
        func close() { sh.windows.forEach { sh.close($0, force: true) }; try? FileManager.default.removeItem(at: dir) }
    }

    private func start() throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); _ = sh.tick()
        try sh.fs.writeFile("C:/Home/Probe.HC", latin1(probe))
        Launch.program(sh, "C:/Home/Probe.HC", nil)
        let app = sh.focused!.app as! ProgramApp
        let r = Run(sh, app.kernel, app, dir)
        XCTAssertTrue(r.waitFor(30) { app.kernel.prog.globals["n"] != nil && app.kernel.frameCount > 5 }, "probe runs")
        return r
    }

    func testPhysicalKeyHoldsAndRepeatsAtTempleOsRate() throws {
        let r = try start(); defer { r.close() }
        let (ch, sc) = Keys.forChar(97)
        r.sh.hardwareKey(ch, sc, true)
        let t0 = Date()
        for _ in 0..<20 { r.sh.hardwareKey(ch, sc, true, platformRepeat: true) }
        XCTAssertTrue(r.waitFor(0.5) { r.bit(Int(sc & 0xFF)) })
        while Date().timeIntervalSince(t0) < 1 { _ = r.sh.tick(); Thread.sleep(forTimeInterval: 0.005) }
        r.sh.hardwareKey(ch, sc, false)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Int(sc & 0xFF)) }, "released")
        r.waitFor(0.3) { false }
        let n = r.g("n")
        XCTAssertTrue((18...28).contains(n), "key-downs in 1 s held: \(n)")
    }

    /** A PC keyboard has one typematic key: pressing B stops A's repeats, and releasing B does not resume them. */
    func testOnlyTheLastPressedKeyRepeats() throws {
        let r = try start(); defer { r.close() }
        let (ca, sa) = Keys.forChar(97)
        let (cb, sb) = Keys.forChar(98)
        func hold(_ s: Double) { let t = Date(); while Date().timeIntervalSince(t) < s { _ = r.sh.tick(); Thread.sleep(forTimeInterval: 0.005) } }
        r.sh.hardwareKey(ca, sa, true)
        hold(0.6)
        XCTAssertTrue(r.waitFor(0.3) { r.g("n") >= 5 }, "A repeats alone")
        r.sh.hardwareKey(cb, sb, true)
        r.waitFor(0.2) { r.g("last") == 98 }
        let n1 = r.g("n")
        hold(0.6)
        r.sh.hardwareKey(cb, sb, false)
        hold(0.5)
        r.sh.hardwareKey(ca, sa, false)
        r.waitFor(0.2) { false }
        XCTAssertEqual(r.g("n"), n1, "A stopped repeating once B was pressed")
    }

    /** Adam/WinMgr.HC close box: a terminal task gets SHIFT-ESC, so the program can save before it ends. */
    func testClosingTheWindowSendsShiftEscFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); _ = sh.tick()
        try sh.fs.writeFile("C:/Home/Closer.HC", latin1("I64 c;do c=GetChar(,FALSE); while (c!=CH_SHIFT_ESC);\nRegWrite(\"Test/Closer\",\"I64 closed=1;\\n\");\n"))
        Launch.program(sh, "C:/Home/Closer.HC", nil)
        let app = sh.focused!.app as! ProgramApp
        let end = Date().addingTimeInterval(30)
        while Date() < end && !app.kernel.waitingForKey { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.01) }
        sh.close(sh.windows.first { $0.app === app }!, force: true)
        let end2 = Date().addingTimeInterval(3)
        while Date() < end2 && !app.kernel.finished { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(app.kernel.finished, "program ended")
        let reg = sh.fs.readFile("C:/Home/Registry.HC").map { latin1($0) } ?? ""
        XCTAssertTrue(reg.contains("closed=1"), "the program saw SHIFT-ESC and saved: \(reg)")
    }

    func testPhysicalCtrlIsAKeyForPrograms() throws {
        let r = try start(); defer { r.close() }
        let (ch, sc) = Keys.special(Keys.SC_CTRL, ctrl: true)
        r.sh.hardwareKey(ch, sc, true)
        XCTAssertTrue(r.waitFor(0.5) { r.bit(Keys.SC_CTRL) }, "SC_CTRL down")
        r.sh.hardwareKey(ch, sc, false)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CTRL) }, "SC_CTRL up")
    }

    func testFocusChangeReleasesHeldPhysicalKeys() throws {
        let r = try start(); defer { r.close() }
        let (ch, sc) = Keys.special(Keys.SC_CURSOR_UP)
        r.sh.hardwareKey(ch, sc, true)
        XCTAssertTrue(r.waitFor(0.5) { r.bit(Keys.SC_CURSOR_UP) })
        Launch.terminal(r.sh)
        r.sh.focus(r.sh.windows.first { $0.app === r.app })
        XCTAssertTrue(r.waitFor(1.5) { !r.bit(Keys.SC_CURSOR_UP) }, "released when another window took the focus")
    }

    private func showKeyboard(_ r: Run) {
        r.app.menu().first { $0.label == tr("program.menu.show_keyboard") }!.action()
        r.sh.invalidate(); _ = r.sh.tick()
    }

    private func key(_ r: Run, _ label: String) -> Rect { r.sh.accessibilityNodes().first { $0.label == label && $0.button }!.rect }

    func testOnScreenKeyIsHeldWhileTouched() throws {
        let r = try start(); defer { r.close() }
        showKeyboard(r)
        let a = key(r, "a")
        let sc = Keys.char2ScanCode(97)
        r.sh.pointer(PointerEvent(Ptr.DOWN, a.x + a.w / 2, a.y + a.h / 2, id: 1, timeMs: r.sh.env.nowMs())); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(0.5) { r.bit(sc) }, "'a' goes down on touch")
        r.waitFor(0.7) { false }
        XCTAssertTrue(r.bit(sc), "still held after 0.7 s")
        XCTAssertGreaterThanOrEqual(r.g("n"), 10, "repeats at the TempleOS rate while held")
        r.sh.pointer(PointerEvent(Ptr.UP, a.x + a.w / 2, a.y + a.h / 2, id: 1, timeMs: r.sh.env.nowMs())); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(1) { !r.bit(sc) }, "up on release")
    }

    func testOnScreenShiftEscIsAbort() throws {
        let r = try start(); defer { r.close() }
        showKeyboard(r)
        func tap(_ label: String) {
            let k = key(r, label)
            r.sh.pointer(PointerEvent(Ptr.DOWN, k.x + k.w / 2, k.y + k.h / 2, id: 2, timeMs: r.sh.env.nowMs())); _ = r.sh.tick()
            r.sh.pointer(PointerEvent(Ptr.UP, k.x + k.w / 2, k.y + k.h / 2, id: 2, timeMs: r.sh.env.nowMs())); _ = r.sh.tick()
        }
        tap("Shift")
        XCTAssertTrue(r.waitFor(0.5) { r.bit(Keys.SC_SHIFT) }, "a running program sees SHIFT go down with the latch")
        tap("Escape")
        XCTAssertTrue(r.waitFor(1) { r.g("last") == Int64(Keys.CH_SHIFT_ESC) }, "SHIFT-ESC (CH_SHIFT_ESC) reached the program")
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_SHIFT) }, "the one-shot SHIFT is released")
    }
}
